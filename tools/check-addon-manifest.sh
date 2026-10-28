#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY FIRST-PARTY ADD-ON KEEPS ITS MANIFEST (TM-1115).
#
#   ./tools/check-addon-manifest.sh              the gate
#   ./tools/check-addon-manifest.sh --selftest   prove it goes red on every mutation, and green untouched
#
# WHY. An add-on is a chart beside the layers, not one of them, and until
# TM-1115 nothing said what that meant. addons/posture-probe shipped in 0.8.0
# ahead of any contract; its values keys sat outside the stability-tier gate, and
# the promises that make it safe to install (no write verb, no route to the
# cluster, off until enabled, what it leaves behind when removed) lived in prose
# and in a gate written for that one add-on. The manifest (addons/<name>/addon.yaml,
# format in addons/README.md) puts them in one machine-readable place, and this
# gate holds each add-on to its own manifest.
#
# WHAT IT ASSERTS, per add-on directory under addons/:
#   1. a manifest exists, parses, names only fields the format knows, and agrees
#      with the chart: same name, same version, same stability, the add-on
#      annotation set.
#   2. the SETTINGS SCHEMA exists, is closed (additionalProperties: false), and the
#      add-on is off by default: `enabled: false` in values.yaml and an empty
#      default render. (Every key's tier and ruling is tools/check-values-tiers.sh,
#      which reads addons/*/chart/values.schema.json beside the layers' schemas.)
#   3. NO CODE IN THE ADMIN ORIGIN: the tree holds no script, page, stylesheet or
#      WebAssembly module a browser could run, and the enabled render holds no
#      Ingress, IngressRoute, HTTPRoute or Gateway-API route, and no Service of
#      type LoadBalancer or NodePort.
#   4. THE OPERATIONS CONTRACT, each claim checked against the render where a
#      render can check it: read-only API access means no verb outside
#      get/list/watch (plus create on the two self-review oracles) and names a
#      safety gate that exists; every PersistentVolumeClaim it renders is declared
#      in operations.data, and everything removal leaves behind is declared there;
#      "no metrics" and "no alerts" mean no ServiceMonitor, PodMonitor or
#      PrometheusRule renders, and a claim of either means one does.
#
# WHAT IT DOES NOT PROVE. That the add-on works (its own gate and the lab do
# that), that the contract is the right one, or anything about a cluster. It does
# not promise anything to a third party: the contract is first-party only, and
# TM-0329 closed on "the extension point stays internal".
#
# EXIT 2 IS SKIPPED, the repository's convention: python3 or PyYAML missing, or
# helm missing (the static checks still run and are reported; a partial run is
# never a pass).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

command -v python3 >/dev/null 2>&1 || { echo "check-addon-manifest: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-addon-manifest: python3 PyYAML missing" >&2; exit 2; }
HAVE_HELM=0
command -v helm >/dev/null 2>&1 && HAVE_HELM=1

# check ROOT : every add-on under ROOT/addons. Prints findings; returns 1 on any,
# 2 when only the render half was skipped.
check() {
  python3 - "$1" "$HAVE_HELM" <<'PY'
import os, re, subprocess, sys, tempfile
import yaml

root, have_helm = sys.argv[1], sys.argv[2] == "1"
findings = []
skipped = []

def bad(addon, msg):
    findings.append(f"  FAIL {addon}: {msg}")

TOP = {"manifestVersion", "name", "title", "summary", "owner", "stability", "docs",
       "chart", "settings", "adminUi", "operations", "render"}
STABILITY = {"experimental", "provisional", "stable"}
BROWSER_CODE = {".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".html", ".htm", ".css",
                ".wasm", ".svg", ".vue"}
ROUTE_KINDS = {"Ingress", "IngressRoute", "IngressRouteTCP", "IngressRouteUDP", "HTTPRoute",
               "GRPCRoute", "TCPRoute", "TLSRoute", "UDPRoute", "Gateway", "Route"}
WRITE_VERBS = {"update", "patch", "delete", "deletecollection", "*", "impersonate",
               "escalate", "bind", "approve", "sign"}
ORACLES = {"selfsubjectaccessreviews", "selfsubjectrulesreviews"}
DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

def unknown(addon, where, d, allowed):
    for k in d:
        if k not in allowed:
            bad(addon, f"{where}: unknown field `{k}` (the format names {sorted(allowed)})")

def need(addon, where, d, keys):
    ok = True
    for k in keys:
        if k not in d:
            bad(addon, f"{where}: missing `{k}`")
            ok = False
    return ok

def helm(chart, ns, sets):
    cmd = ["helm", "template", "t", chart, "-n", ns]
    for k, v in sets:
        cmd += ["--set", f"{k}={v}"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr

addons_dir = os.path.join(root, "addons")
if not os.path.isdir(addons_dir):
    print("check-addon-manifest: REFUSING ... no addons/ directory; the scan is wrong")
    sys.exit(1)
names = sorted(d for d in os.listdir(addons_dir)
               if os.path.isdir(os.path.join(addons_dir, d)) and not d.startswith("."))
if not names:
    print("check-addon-manifest: REFUSING ... addons/ holds no add-on; a gate that examines nothing must not pass")
    sys.exit(1)

for name in names:
    adir = os.path.join(addons_dir, name)
    mpath = os.path.join(adir, "addon.yaml")
    if not os.path.isfile(mpath):
        bad(name, "no addon.yaml (every directory under addons/ is an add-on and needs a manifest; format in addons/README.md)")
        continue
    try:
        m = yaml.safe_load(open(mpath))
    except yaml.YAMLError as e:
        bad(name, f"addon.yaml does not parse: {e}")
        continue
    if not isinstance(m, dict):
        bad(name, "addon.yaml is not a mapping")
        continue
    unknown(name, "addon.yaml", m, TOP)
    if not need(name, "addon.yaml", m, sorted(TOP)):
        continue
    if m["manifestVersion"] != 1:
        bad(name, f"manifestVersion is {m['manifestVersion']!r}; this gate reads 1")
    if m["owner"] != "first-party":
        bad(name, f"owner is {m['owner']!r}; the contract is first-party only (TM-0329)")
    if m["name"] != name:
        bad(name, f"name `{m['name']}` differs from the directory `{name}`")
    if m["stability"] not in STABILITY:
        bad(name, f"stability {m['stability']!r} is not one of {sorted(STABILITY)}")

    # ---- the chart -------------------------------------------------------
    ch = m["chart"] if isinstance(m["chart"], dict) else {}
    unknown(name, "chart", ch, {"path", "version"})
    need(name, "chart", ch, ["path", "version"])
    chart_dir = os.path.join(adir, str(ch.get("path", "chart")))
    cy = os.path.join(chart_dir, "Chart.yaml")
    chart = {}
    if not os.path.isfile(cy):
        bad(name, f"chart.path `{ch.get('path')}` has no Chart.yaml")
    else:
        chart = yaml.safe_load(open(cy)) or {}
        ann = chart.get("annotations") or {}
        if chart.get("name") != name:
            bad(name, f"Chart.yaml name `{chart.get('name')}` differs from the add-on `{name}`")
        if str(chart.get("version")) != str(ch.get("version")):
            bad(name, f"chart.version `{ch.get('version')}` differs from Chart.yaml version `{chart.get('version')}`")
        if str(ann.get("tockmox.com/addon")) != "true":
            bad(name, "Chart.yaml lacks the annotation tockmox.com/addon: \"true\"")
        if ann.get("tockmox.com/stability") != m["stability"]:
            bad(name, f"stability `{m['stability']}` differs from the Chart.yaml annotation tockmox.com/stability `{ann.get('tockmox.com/stability')}`")
    if not os.path.isfile(os.path.join(root, str(m["docs"]))):
        bad(name, f"docs `{m['docs']}` does not exist")

    # ---- the settings schema --------------------------------------------
    st = m["settings"] if isinstance(m["settings"], dict) else {}
    unknown(name, "settings", st, {"schema", "defaultEnabled"})
    need(name, "settings", st, ["schema", "defaultEnabled"])
    spath = os.path.join(adir, str(st.get("schema", "")))
    if not os.path.isfile(spath):
        bad(name, f"settings.schema `{st.get('schema')}` does not exist")
    else:
        import json
        try:
            schema = json.load(open(spath))
        except ValueError as e:
            schema = {}
            bad(name, f"settings.schema does not parse: {e}")
        if schema.get("additionalProperties") is not False:
            bad(name, "settings.schema is open: set additionalProperties: false at the top, so a mistyped key is refused rather than ignored")
        if not isinstance(schema.get("properties"), dict) or not schema.get("properties"):
            bad(name, "settings.schema declares no properties")
    if st.get("defaultEnabled") is not False:
        bad(name, "settings.defaultEnabled must be false: a first-party add-on is off until enabled")
    vpath = os.path.join(chart_dir, "values.yaml")
    if os.path.isfile(vpath):
        vals = yaml.safe_load(open(vpath)) or {}
        if vals.get("enabled") is not False:
            bad(name, "values.yaml does not set `enabled: false`; the add-on must be off by default")
    else:
        bad(name, "chart has no values.yaml")

    # ---- no code in the admin origin ------------------------------------
    ui = m["adminUi"] if isinstance(m["adminUi"], dict) else {}
    unknown(name, "adminUi", ui, {"code", "exposes"})
    need(name, "adminUi", ui, ["code", "exposes"])
    if ui.get("code") != "none":
        bad(name, f"adminUi.code is {ui.get('code')!r}; an add-on ships no code the admin console loads or runs (must be `none`)")
    if ui.get("exposes") != "none":
        bad(name, f"adminUi.exposes is {ui.get('exposes')!r}; an add-on exposes no route to the cluster (must be `none`)")
    for dp, dn, fn in os.walk(adir):
        dn[:] = [d for d in dn if d != "__pycache__" and not d.startswith(".")]
        for f in fn:
            if os.path.splitext(f)[1].lower() in BROWSER_CODE:
                bad(name, f"{os.path.relpath(os.path.join(dp, f), root)} is browser-executable code; an add-on ships none (no code in the admin origin)")

    # ---- the operations contract ----------------------------------------
    op = m["operations"] if isinstance(m["operations"], dict) else {}
    unknown(name, "operations", op, {"install", "access", "containment", "data", "observability", "upgrade", "removal", "support"})
    need(name, "operations", op, ["install", "access", "containment", "data", "observability", "upgrade", "removal", "support"])
    ins = op.get("install") if isinstance(op.get("install"), dict) else {}
    unknown(name, "operations.install", ins, {"mode", "namespace", "needs"})
    if ins.get("mode") != "standalone-application":
        bad(name, f"operations.install.mode is {ins.get('mode')!r}; an add-on installs as its own application, never as a layer (`standalone-application`)")
    if not (isinstance(ins.get("namespace"), str) and DNS_LABEL.match(ins.get("namespace", "")) and len(ins["namespace"]) <= 63):
        bad(name, "operations.install.namespace must be a DNS label")
    if not isinstance(ins.get("needs"), list):
        bad(name, "operations.install.needs must be a list (empty when nothing must be present first)")
    acc = op.get("access") if isinstance(op.get("access"), dict) else {}
    unknown(name, "operations.access", acc, {"kubernetesApi", "safetyGate"})
    api = acc.get("kubernetesApi")
    if api not in ("none", "read-only"):
        bad(name, f"operations.access.kubernetesApi is {api!r}; the contract allows `none` or `read-only`")
    if api == "read-only":
        g = acc.get("safetyGate")
        if not (isinstance(g, str) and os.path.isfile(os.path.join(root, g))):
            bad(name, f"operations.access.safetyGate `{g}` does not exist; read-only access is held by a gate of its own")
    con = op.get("containment") if isinstance(op.get("containment"), dict) else {}
    unknown(name, "operations.containment", con, {"touchesRunningServices", "egress"})
    if con.get("touchesRunningServices") is not False:
        bad(name, "operations.containment.touchesRunningServices must be false")
    if con.get("egress") not in ("none", "declared-endpoints-only"):
        bad(name, f"operations.containment.egress is {con.get('egress')!r}; allowed: none, declared-endpoints-only")
    data = op.get("data") if isinstance(op.get("data"), list) else None
    declared = {}
    if data is None:
        bad(name, "operations.data must be a list (empty when the add-on stores nothing)")
        data = []
    for i, e in enumerate(data):
        if not isinstance(e, dict):
            bad(name, f"operations.data[{i}] is not a mapping")
            continue
        unknown(name, f"operations.data[{i}]", e, {"name", "kind", "sensitive", "backedUp"})
        if not need(name, f"operations.data[{i}]", e, ["name", "kind", "sensitive", "backedUp"]):
            continue
        if e["kind"] not in ("persistentvolumeclaim", "configmap", "secret"):
            bad(name, f"operations.data[{i}].kind {e['kind']!r} is not persistentvolumeclaim, configmap or secret")
        if not isinstance(e["sensitive"], bool) or not isinstance(e["backedUp"], bool):
            bad(name, f"operations.data[{i}]: sensitive and backedUp are true or false")
        if e["kind"] == "secret" and e["sensitive"] is not True:
            bad(name, f"operations.data[{i}]: a secret is sensitive")
        declared[e["name"]] = e
    obs = op.get("observability") if isinstance(op.get("observability"), dict) else {}
    unknown(name, "operations.observability", obs, {"metrics", "alerts", "logs"})
    if obs.get("metrics") not in ("none", "servicemonitor"):
        bad(name, f"operations.observability.metrics is {obs.get('metrics')!r}; allowed: none, servicemonitor")
    if obs.get("alerts") not in ("none", "prometheusrule"):
        bad(name, f"operations.observability.alerts is {obs.get('alerts')!r}; allowed: none, prometheusrule")
    if obs.get("logs") not in ("counts-only", "standard"):
        bad(name, f"operations.observability.logs is {obs.get('logs')!r}; allowed: counts-only, standard")
    up = op.get("upgrade") if isinstance(op.get("upgrade"), dict) else {}
    unknown(name, "operations.upgrade", up, {"versioning", "path"})
    if up.get("versioning") != "own-chart-version":
        bad(name, f"operations.upgrade.versioning is {up.get('versioning')!r}; an add-on is versioned on its own (`own-chart-version`)")
    if up.get("path") not in ("replace-chart-version", "documented-migration"):
        bad(name, f"operations.upgrade.path is {up.get('path')!r}; allowed: replace-chart-version, documented-migration")
    rem = op.get("removal") if isinstance(op.get("removal"), dict) else {}
    unknown(name, "operations.removal", rem, {"doc", "leaves"})
    if not os.path.isfile(os.path.join(root, str(rem.get("doc", "")))):
        bad(name, f"operations.removal.doc `{rem.get('doc')}` does not exist")
    leaves = rem.get("leaves")
    if not isinstance(leaves, list):
        bad(name, "operations.removal.leaves must be a list (empty when removal leaves nothing)")
        leaves = []
    for l in leaves:
        if l not in declared:
            bad(name, f"operations.removal.leaves names `{l}`, which operations.data does not declare: what removal leaves behind must be declared as data")
    if op.get("support") not in ("experimental", "supported"):
        bad(name, f"operations.support is {op.get('support')!r}; allowed: experimental, supported")
    elif (op["support"] == "experimental") != (m["stability"] == "experimental"):
        bad(name, f"operations.support `{op['support']}` does not match stability `{m['stability']}`")

    # ---- the render -------------------------------------------------------
    rn = m["render"] if isinstance(m["render"], dict) else {}
    unknown(name, "render", rn, {"set"})
    sets = rn.get("set") if isinstance(rn.get("set"), dict) else None
    if sets is None:
        bad(name, "render.set must be a mapping of the values that switch the add-on on for a CI render")
        continue
    if not have_helm:
        skipped.append(name)
        continue
    ns = ins.get("namespace") if isinstance(ins.get("namespace"), str) else "tockmox-addon"
    chart_arg = chart_dir
    rc, out, err = helm(chart_arg, ns, [])
    if rc != 0:
        bad(name, f"the default render failed: {err.strip().splitlines()[-1] if err.strip() else rc}")
    elif re.search(r"^kind:", out, re.M):
        bad(name, "the default render is not empty: the add-on must be off until enabled")
    rc, out, err = helm(chart_arg, ns, [(k, v) for k, v in sets.items()])
    if rc != 0:
        bad(name, f"the enabled render (render.set) failed: {err.strip().splitlines()[-1] if err.strip() else rc}")
        continue
    docs = [d for d in yaml.safe_load_all(out) if isinstance(d, dict)]
    kinds = {}
    for d in docs:
        kinds.setdefault(d.get("kind"), []).append(d)
    for k in sorted(set(kinds) & ROUTE_KINDS):
        bad(name, f"the enabled render holds a {k}: an add-on exposes no route to the cluster (no code in the admin origin, no new origin)")
    for s in kinds.get("Service", []):
        t = (s.get("spec") or {}).get("type", "ClusterIP")
        if t in ("LoadBalancer", "NodePort"):
            bad(name, f"Service {s['metadata'].get('name')} is type {t}: an add-on exposes nothing outside the cluster")
    if api == "read-only":
        for kind in ("Role", "ClusterRole"):
            for r in kinds.get(kind, []):
                for rule in r.get("rules") or []:
                    verbs = set(rule.get("verbs") or [])
                    res = set(rule.get("resources") or [])
                    w = verbs & WRITE_VERBS
                    if w:
                        bad(name, f"{kind} {r['metadata'].get('name')} holds write verb(s) {sorted(w)} but the manifest says kubernetesApi: read-only")
                    if "create" in verbs and not res <= ORACLES:
                        bad(name, f"{kind} {r['metadata'].get('name')} can create {sorted(res - ORACLES)}: read-only allows create only on {sorted(ORACLES)}")
    rendered_pvcs = {p["metadata"]["name"] for p in kinds.get("PersistentVolumeClaim", [])}
    declared_pvcs = {n for n, e in declared.items() if e.get("kind") == "persistentvolumeclaim"}
    for p in sorted(rendered_pvcs - declared_pvcs):
        bad(name, f"PersistentVolumeClaim `{p}` renders but is not declared in operations.data")
    for p in sorted(declared_pvcs - rendered_pvcs):
        bad(name, f"operations.data declares PersistentVolumeClaim `{p}` but the enabled render holds none by that name")
    has_metrics = bool(set(kinds) & {"ServiceMonitor", "PodMonitor"})
    has_alerts = "PrometheusRule" in kinds
    if obs.get("metrics") == "none" and has_metrics:
        bad(name, "operations.observability.metrics is none but the render holds a ServiceMonitor or PodMonitor")
    if obs.get("metrics") == "servicemonitor" and not has_metrics:
        bad(name, "operations.observability.metrics is servicemonitor but the render holds none")
    if obs.get("alerts") == "none" and has_alerts:
        bad(name, "operations.observability.alerts is none but the render holds a PrometheusRule")
    if obs.get("alerts") == "prometheusrule" and not has_alerts:
        bad(name, "operations.observability.alerts is prometheusrule but the render holds none")

for f in findings:
    print(f)
if findings:
    print(f"check-addon-manifest: FAILED ({len(findings)} finding(s) across {len(names)} add-on(s))")
    sys.exit(1)
for n in names:
    if n in skipped:
        print(f"  ok   {n}: manifest, chart agreement, settings schema, no browser code (render checks SKIPPED: helm is not on PATH)")
    else:
        print(f"  ok   {n}: manifest, chart agreement, settings schema, no code in the admin origin, operations contract against the render")
if skipped:
    print("check-addon-manifest: INCOMPLETE ... the render checks need helm; exit 2, not a pass")
    sys.exit(2)
print(f"check-addon-manifest: ok ({len(names)} add-on(s))")
PY
}

if [ "${1:-}" != "--selftest" ]; then
  check "."
  exit $?
fi

# --- selftest: every mutation must turn the gate red for its own reason; the untouched copy green ---
[ "$HAVE_HELM" -eq 1 ] || { echo "check-addon-manifest --selftest: helm missing" >&2; exit 2; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
fresh() { # fresh NAME : a copy of the real add-on tree to mutate
  rm -rf "${work:?}/$1"; mkdir -p "$work/$1"
  cp -R addons "$work/$1/addons"
  mkdir -p "$work/$1/docs/administration" "$work/$1/tools"
  cp docs/administration/posture-probe.md "$work/$1/docs/administration/"
  cp tools/check-posture-probe.sh "$work/$1/tools/"
  find "$work/$1" -name __pycache__ -type d -prune -exec rm -rf {} +
}
red() { # red LABEL NEEDLE DIR : the gate must fail on DIR and name NEEDLE
  local out rc
  out=$(check "$3" 2>&1); rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -F -- "$2" >/dev/null; then echo "  ok  $1"
  else echo "  SELFTEST FAIL: '$1' wanted exit 1 naming '$2', got exit $rc:"; printf '%s\n' "$out" | sed 's/^/            /' | head -12; fail=1; fi
}
P="addons/posture-probe"
edit() { # edit DIR FILE OLD NEW : replace one literal in a file of the copy
  python3 - "$1/$2" "$3" "$4" <<'PY'
import sys
p, a, b = sys.argv[1:4]
t = open(p).read()
assert a in t, f"selftest fixture drifted: {a!r} not in {p}"
open(p, "w").write(t.replace(a, b, 1))
PY
}

fresh clean
out=$(check "$work/clean" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then echo "  ok  the untouched add-on tree is accepted"
else echo "  SELFTEST FAIL: the untouched copy should be accepted (exit $rc):"; printf '%s\n' "$out" | sed 's/^/            /' | head; fail=1; fi

fresh m; rm "$work/m/$P/addon.yaml"
red "an add-on directory with no manifest is refused" "no addon.yaml" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "version: 0.1.0 " "version: 0.2.0 "
red "a manifest version that differs from Chart.yaml is refused" "chart.version" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "stability: experimental       #" "stability: provisional       #"
red "a manifest stability that differs from the chart annotation is refused" "tockmox.com/stability" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "owner: first-party" "owner: first-party
sidecar: true"
red "a field the format does not name is refused" "unknown field \`sidecar\`" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "  code: none" "  code: bundle"
red "a manifest that admits code in the admin origin is refused" "adminUi.code" "$work/m"
fresh m; mkdir -p "$work/m/$P/ui"; echo 'alert(1)' > "$work/m/$P/ui/app.js"
red "a script planted in the add-on tree is refused" "browser-executable" "$work/m"
fresh m; mkdir -p "$work/m/$P/ui"; echo '<script></script>' > "$work/m/$P/ui/panel.html"
red "a page planted in the add-on tree is refused" "browser-executable" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-route.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: planted
spec:
  rules: []
{{- end }}
EOF
red "an Ingress planted in the enabled render is refused" "holds a Ingress" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-svc.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: planted
spec:
  type: NodePort
  ports: [{port: 80}]
{{- end }}
EOF
red "a NodePort Service planted in the enabled render is refused" "type NodePort" "$work/m"
fresh m; edit "$work/m" "$P/chart/values.yaml" "enabled: false" "enabled: true"
red "an add-on that renders by default is refused" "off by default" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-role.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: planted
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "patch"]
{{- end }}
EOF
red "a write verb planted in a read-only add-on is refused" "write verb(s) ['patch']" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-role.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: planted
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
{{- end }}
EOF
red "a create on pods planted in a read-only add-on is refused" "read-only allows create only on" "$work/m"
fresh m; rm "$work/m/tools/check-posture-probe.sh"
red "read-only access with no safety gate on disk is refused" "safetyGate" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-pvc.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: planted-claim
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
{{- end }}
EOF
red "a claim the manifest does not declare is refused" "not declared in operations.data" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "      - posture-probe-reports         #" "      - something-else                #"
red "a removal leftover that is not declared data is refused" "operations.removal.leaves" "$work/m"
fresh m; cat > "$work/m/$P/chart/templates/zz-mon.yaml" <<'EOF'
{{- if .Values.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: planted
spec:
  selector: {}
  endpoints: []
{{- end }}
EOF
red "a ServiceMonitor in an add-on that claims no metrics is refused" "metrics is none but the render holds a ServiceMonitor" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "schema: chart/values.schema.json" "schema: chart/nothing.json"
red "a settings schema that does not exist is refused" "settings.schema" "$work/m"
fresh m; python3 - "$work/m/$P/chart/values.schema.json" <<'PY'
import json, sys
p = sys.argv[1]
s = json.load(open(p)); s["additionalProperties"] = True
json.dump(s, open(p, "w"))
PY
red "an open settings schema is refused" "settings.schema is open" "$work/m"
fresh m; edit "$work/m" "$P/addon.yaml" "namespace: tockmox-posture " "namespace: Tockmox_Posture "
red "a namespace that is not a DNS label is refused" "DNS label" "$work/m"

if [ "$fail" -eq 0 ]; then echo "check-addon-manifest --selftest: PASSED"; exit 0; fi
echo "check-addon-manifest --selftest: FAILED"; exit 1

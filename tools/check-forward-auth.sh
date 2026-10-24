#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Forward-auth consoles (TM-0425, TM-0217), asserted on the render.
#
#   ./tools/check-forward-auth.sh              render and assert
#   ./tools/check-forward-auth.sh --selftest   prove every assertion can go red
#
# A forward-auth console is two halves in two layers that cannot read each
# other's values: the identity layer's proxy provider, Middleware and sign-in
# callback route, and the console layer's route that attaches the Middleware.
# Every half can render cleanly while the pair does nothing: a route naming a
# Middleware that is not where it says, a provider for a host no route serves, a
# callback on a different host, an outpost that serves none of the providers.
# Nothing fails at render for any of those; Traefik answers 404 or Authentik
# loops on its login. So this gate renders the layers TOGETHER and asserts that
# the halves name each other.
#
#   F1  default: no route, no Middleware, no callback Ingress, no outpost entry;
#       every forward-auth provider and application rendered `state: absent`.
#   F2  all four consoles on: one Middleware, pointing at THIS release's
#       Authentik server Service and the traefik outpost path; per console a
#       `forward_single` provider whose external_host is the route's host, an
#       application bound to it with a group binding, a callback Ingress for
#       /outpost.goauthentik.io/ on the same host with TLS; the embedded outpost
#       (by `managed`) serves exactly the four providers; every console route
#       attaches the Middleware by the namespace and name it was rendered with.
#   F3  identity capability off with a route on fails the render;
#       `forwardAuth: false` renders the route with no Middleware.
#   F4  a host override given to both halves moves the provider, the callback
#       and the route together.
#   F5  keepProviders adds its names to the outpost list (by name lookup).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v helm >/dev/null 2>&1 || { echo "check-forward-auth: SKIPPED (helm not on PATH)"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-forward-auth: SKIPPED (python3 has no PyYAML)"; exit 2; }

VALUES="ci/values.yaml"
ID_NS="tockmox-authentik"

render() { # <chart> <namespace> <out> [--set ...]
  local chart="$1" ns="$2" out="$3"; shift 3
  # FA_CHARTS is read per call, not once at load: the selftest points it at a
  # mutated copy for one run at a time.
  helm template "tockmox-$chart" "${FA_CHARTS:-charts}/tockmox-$chart" -n "$ns" -f "$VALUES" "$@" > "$out" 2>&1
}

ALL_ID=(--set sso.forwardAuth.apps.prometheus.enabled=true --set sso.forwardAuth.apps.alertmanager.enabled=true
        --set sso.forwardAuth.apps.longhorn.enabled=true --set sso.forwardAuth.apps.traefik.enabled=true
        --set global.certIssuer=tockmox-ca)
ALL_OBS=(--set ingress.apps.prometheus.enabled=true --set ingress.apps.alertmanager.enabled=true --set global.certIssuer=tockmox-ca)
ALL_PLAT=(--set ingress.apps.longhorn.enabled=true --set ingress.apps.traefik.enabled=true --set global.certIssuer=tockmox-ca)

assert_py() { # <mode> <files...>; python reads the renders and asserts
  python3 - "$@" <<'PY'
import sys, yaml
mode, files = sys.argv[1], sys.argv[2:]

class L(yaml.SafeLoader): pass
def tag(loader, suffix, node):
    if isinstance(node, yaml.ScalarNode): return {"!" + suffix: loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode): return {"!" + suffix: loader.construct_sequence(node, deep=True)}
    return {"!" + suffix: loader.construct_mapping(node, deep=True)}
L.add_multi_constructor("!", tag)

def docs(path):
    out = []
    try:
        for d in yaml.safe_load_all(open(path)):
            if isinstance(d, dict): out.append(d)
    except yaml.YAMLError:
        print("FAIL  a render did not produce YAML (%s): %s" % (path.rsplit("/", 1)[-1], open(path).readline().strip()[:200]))
        sys.exit(1)
    return out

def fail(msg):
    print("FAIL  " + msg); sys.exit(1)

ident, obs, plat = (docs(f) for f in files[:3])
ID_NS = "tockmox-authentik"

def find(ds, kind, name=None):
    return [d for d in ds if d.get("kind") == kind and (name is None or d["metadata"]["name"] == name)]

def blueprint(ds):
    cm = find(ds, "ConfigMap", "tockmox-sso-blueprints")
    if not cm: fail("no tockmox-sso-blueprints ConfigMap in the identity render")
    raw = cm[0]["data"].get("tockmox-forward-auth.yaml")
    if raw is None: fail("the blueprint ConfigMap has no tockmox-forward-auth.yaml")
    return yaml.load(raw, Loader=L)["entries"]

def route_host_and_ref(console):
    if console == "traefik":
        ir = find(plat, "IngressRoute", "traefik-dashboard")
        if not ir: return None, None
        r = ir[0]["spec"]["routes"][0]
        host = r["match"].split("Host(`")[1].split("`")[0]
        mws = [m["name"] for m in r.get("middlewares", [])]
        return host, (mws[0] if mws else None)
    ds = plat if console == "longhorn" else obs
    ing = find(ds, "Ingress", console)
    if not ing: return None, None
    a = ing[0]["metadata"].get("annotations") or {}
    return ing[0]["spec"]["rules"][0]["host"], a.get("traefik.ingress.kubernetes.io/router.middlewares")

CONSOLES = ["prometheus", "alertmanager", "longhorn", "traefik"]
entries = blueprint(ident)

if mode == "default":
    if find(ident, "Middleware", "tockmox-forward-auth"): fail("F1 a Middleware renders with every console off")
    if [i for i in find(ident, "Ingress") if i["metadata"]["name"].startswith("forward-auth-")]: fail("F1 a callback Ingress renders with every console off")
    if [e for e in entries if e["model"] == "authentik_outposts.outpost"]: fail("F1 the embedded outpost is touched with every console off")
    for e in entries:
        if e["model"] in ("authentik_providers_proxy.proxyprovider", "authentik_core.application") and e["state"] != "absent":
            fail("F1 %s %s is not absent with its console off" % (e["model"], e["identifiers"]))
    for c in CONSOLES:
        if route_host_and_ref(c)[0]: fail("F1 a %s route renders by default" % c)
    print("ok    F1 default: no route, Middleware, callback or outpost entry; every forward-auth object absent")
    sys.exit(0)

if mode in ("all", "override"):
    mw = find(ident, "Middleware", "tockmox-forward-auth")
    if len(mw) != 1: fail("F2 expected one tockmox-forward-auth Middleware, found %d" % len(mw))
    addr = mw[0]["spec"]["forwardAuth"]["address"]
    if addr != "http://tockmox-identity-authentik-server.%s.svc.cluster.local/outpost.goauthentik.io/auth/traefik" % ID_NS:
        fail("F2 the Middleware address is not this release's Authentik server outpost path: %s" % addr)
    svc = find(ident, "Service", "tockmox-identity-authentik-server")
    if not svc or 80 not in [p["port"] for p in svc[0]["spec"]["ports"]]:
        fail("F2 the Middleware names tockmox-identity-authentik-server:80, which the render does not serve")
    ref = "%s-tockmox-forward-auth@kubernetescrd" % ID_NS
    providers = {e["identifiers"]["name"]: e for e in entries if e["model"] == "authentik_providers_proxy.proxyprovider"}
    apps = {e["id"]: e for e in entries if e["model"] == "authentik_core.application"}
    for c in CONSOLES:
        host, mref = route_host_and_ref(c)
        if not host: fail("F2 no %s route with the console on" % c)
        if mref != ref: fail("F2 the %s route attaches %r, not the rendered Middleware %r" % (c, mref, ref))
        p = providers.get("tockmox-fa-" + c)
        if not p or p["state"] != "present": fail("F2 no present provider for %s" % c)
        if p["attrs"].get("mode") != "forward_single": fail("F2 the %s provider is not forward_single" % c)
        if p["attrs"].get("external_host") != "https://" + host:
            fail("F2 the %s provider's external_host %s is not its route's host %s" % (c, p["attrs"].get("external_host"), host))
        a = apps.get("app-fa-" + c)
        if not a or a["attrs"].get("provider") != {"!KeyOf": "provider-fa-" + c}: fail("F2 the %s application is not bound to its provider" % c)
        if not [e for e in entries if e["model"] == "authentik_policies.policybinding" and e["state"] == "present"
                and e["identifiers"].get("target") == {"!KeyOf": "app-fa-" + c}]:
            fail("F2 the %s application has no group binding" % c)
        cb = find(ident, "Ingress", "forward-auth-" + c)
        if not cb: fail("F2 no sign-in callback Ingress for %s" % c)
        rule = cb[0]["spec"]["rules"][0]
        if rule["host"] != host: fail("F2 the %s callback is on %s, the route on %s" % (c, rule["host"], host))
        paths = rule["http"]["paths"]
        if [x["path"] for x in paths] != ["/outpost.goauthentik.io/"]: fail("F2 the %s callback routes %s, not only /outpost.goauthentik.io/" % (c, [x["path"] for x in paths]))
        if paths[0]["backend"]["service"]["name"] != "tockmox-identity-authentik-server": fail("F2 the %s callback does not reach the Authentik server" % c)
        if not cb[0]["spec"].get("tls"): fail("F2 the %s callback has no TLS while the route has" % c)
    out = [e for e in entries if e["model"] == "authentik_outposts.outpost"]
    if len(out) != 1 or out[0]["identifiers"] != {"managed": "goauthentik.io/outposts/embedded"}:
        fail("F2 the embedded outpost is not set exactly once, by its managed marker")
    keyofs = sorted(x["!KeyOf"] for x in out[0]["attrs"]["providers"] if "!KeyOf" in x)
    if keyofs != sorted("provider-fa-" + c for c in CONSOLES): fail("F2 the outpost serves %s, not the four consoles" % keyofs)
    if mode == "override":
        h = route_host_and_ref("prometheus")[0]
        if h != "metrics.example.org": fail("F4 the prometheus route did not move to the override host (%s)" % h)
        finds = [x for x in out[0]["attrs"]["providers"] if "!Find" in x]
        if finds != [{"!Find": ["authentik_providers_proxy.proxyprovider", ["name", "site-proxy"]]}]:
            fail("F5 keepProviders did not add site-proxy to the outpost by name: %s" % finds)
        print("ok    F4 a host override moves provider, callback and route together")
        print("ok    F5 keepProviders keeps a site provider on the embedded outpost")
    else:
        print("ok    F2 four consoles: one Middleware on this release's outpost, providers, bindings, callbacks and routes that name each other")
    sys.exit(0)
fail("unknown mode " + mode)
PY
}

run_checks() { local rc=0; RC_T="$(mktemp -d)"; run_checks_in "$RC_T" || rc=1; rm -rf "$RC_T"; return $rc; }

run_checks_in() {
  local t="$1"
  render identity "$ID_NS" "$t/id0"
  render observability tockmox-monitoring "$t/ob0"
  render platform tockmox-platform "$t/pl0"
  assert_py default "$t/id0" "$t/ob0" "$t/pl0" || return 1

  render identity "$ID_NS" "$t/id1" "${ALL_ID[@]}"
  render observability tockmox-monitoring "$t/ob1" "${ALL_OBS[@]}"
  render platform tockmox-platform "$t/pl1" "${ALL_PLAT[@]}"
  assert_py all "$t/id1" "$t/ob1" "$t/pl1" || return 1

  # F3: the refusal and the explicit opt-out.
  if render observability tockmox-monitoring "$t/ob3" --set ingress.apps.prometheus.enabled=true --set capabilities.identity.enabled=false; then
    echo "FAIL  F3 a prometheus route rendered with the identity capability off"; return 1
  fi
  grep -q "capabilities.identity is off" "$t/ob3" || { echo "FAIL  F3 the refusal does not name the identity capability"; return 1; }
  render observability tockmox-monitoring "$t/ob4" --set ingress.apps.prometheus.enabled=true \
    --set ingress.apps.prometheus.forwardAuth=false --set capabilities.identity.enabled=false \
    || { echo "FAIL  F3 forwardAuth: false did not render"; return 1; }
  python3 - "$t/ob4" <<'PY' || return 1
import sys, yaml
ing = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict) and d.get("kind") == "Ingress" and d["metadata"]["name"] == "prometheus"]
if not ing: print("FAIL  F3 forwardAuth: false rendered no prometheus route"); sys.exit(1)
if "traefik.ingress.kubernetes.io/router.middlewares" in (ing[0]["metadata"].get("annotations") or {}):
    print("FAIL  F3 forwardAuth: false still attached the Middleware"); sys.exit(1)
print("ok    F3 identity off refuses the route; forwardAuth: false routes it without the Middleware")
PY

  render identity "$ID_NS" "$t/id5" "${ALL_ID[@]}" --set sso.forwardAuth.apps.prometheus.host=metrics.example.org \
    --set 'sso.forwardAuth.keepProviders={site-proxy}'
  render observability tockmox-monitoring "$t/ob5" "${ALL_OBS[@]}" --set ingress.apps.prometheus.host=metrics.example.org
  assert_py override "$t/id5" "$t/ob5" "$t/pl1" || return 1
}

selftest() {
  # Each mutation breaks one seam in a scratch copy of the charts; the gate must go red on every one.
  local t fails=0; t="$(mktemp -d)"
  mutate() { # <label> <file under charts/> <sed expression>
    rm -rf "$t/charts"; cp -R charts "$t/charts"
    sed "$3" "charts/$2" > "$t/charts/$2"
    if cmp -s "charts/$2" "$t/charts/$2"; then echo "SELFTEST-FAIL  mutation did not change $2 ($1)"; fails=$((fails + 1)); return; fi
    # tockmox-common reaches the layers as a vendored package, not as source:
    # repackage it into each layer's charts/ or the mutation never renders.
    case "$2" in tockmox-common/*)
      for l in identity observability platform; do
        helm package "$t/charts/tockmox-common" -d "$t/charts/tockmox-$l/charts" >/dev/null
      done ;;
    esac
    local why
    if why="$(FA_CHARTS="$t/charts" run_checks 2>&1)"; then
      echo "SELFTEST-FAIL  still green with: $1"; fails=$((fails + 1))
    else
      # Say WHICH assertion caught it: red for an unrelated reason (a render
      # error, say) would read as coverage and be none.
      echo "red   $1"
      echo "$why" | grep -m1 '^FAIL' | sed 's/^/        caught by: /' || echo "        caught by: (no FAIL line; read the render)"
    fi
  }
  mutate "the prometheus route drops the Middleware" tockmox-observability/templates/ingress.yaml 's/"on" .forwardAuth) | fromYaml/"on" false) | fromYaml/'
  mutate "providers in forward_domain mode" tockmox-identity/templates/sso-blueprints.yaml 's/mode: forward_single/mode: forward_domain/'
  mutate "the callback routes the whole host" tockmox-identity/templates/forward-auth.yaml 's|path: /outpost.goauthentik.io/|path: /|'
  # shellcheck disable=SC2016  # the $ is Helm template text the mutation must match literally, not a shell variable
  mutate "the Middleware points at another Service" tockmox-identity/templates/forward-auth.yaml 's|http://{{ $server }}|http://authentik|'
  mutate "the console route names a Middleware nobody renders" tockmox-common/templates/_helpers.tpl 's/tockmox-authentik-tockmox-forward-auth@kubernetescrd/tockmox-platform-forward-auth@kubernetescrd/'
  mutate "the outpost entry is dropped" tockmox-identity/templates/sso-blueprints.yaml 's/model: authentik_outposts.outpost/model: authentik_outposts.outpostx/'
  mutate "the identity refusal is removed" tockmox-common/templates/_helpers.tpl 's/{{- if not (include "tockmox.capabilityEnabled" (dict "ctx" .ctx "capability" "identity")) -}}/{{- if false -}}/'
  # shellcheck disable=SC2016  # the $ is Helm template text the mutation must match literally, not a shell variable
  mutate "disabled consoles left present" tockmox-identity/templates/sso-blueprints.yaml 's/state: {{ ternary "present" "absent" $on }}/state: present/'
  rm -rf "$t"
  if [ "$fails" -eq 0 ]; then echo "selftest: every assertion can go red"; return 0; fi
  echo "selftest: $fails mutation(s) stayed green" >&2; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "") run_checks && echo "check-forward-auth: all checks passed" ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

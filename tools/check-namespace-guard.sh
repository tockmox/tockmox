#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# THE NAMESPACE GUARD ADMITS EVERY IDENTITY THE PRODUCT RUNS AS AND REFUSES THE
# ONES IT SHOULD.
#
#   ./tools/check-namespace-guard.sh              the gate
#   ./tools/check-namespace-guard.sh --selftest   plant one defect per rule and require red, then green untouched
#
# WHY. tockmox-policy ships a ValidatingAdmissionPolicy (apps.namespace_guard, off
# by default, Warn when on) that refuses a CREATE in a namespace the chart manages
# unless the requester is GitOps or the platform. An exemption list that is wrong
# in one direction blocks a sync (Deny turned on, a controller refused); wrong in
# the other it guards nothing. Neither shows in `helm template`, `helm lint` or
# kubeconform: the expression is a string until an API server evaluates it.
#
# WHAT IT DOES. It renders the policy layer, takes the guard's matchCondition
# (the only place an exemption is written) and EVALUATES it with a CEL
# implementation (cel-python) against identities:
#   1. every ServiceAccount the shipped charts create or bind, in all nine layers,
#      with the CI defaults and with the all-on overlay, must be ADMITTED. This is
#      the exemption list re-derived from the product on every run, so a layer
#      that starts running a controller in a new namespace fails here and not on
#      the first Deny;
#   2. Argo CD's and kube-system's ServiceAccounts, a kubelet, the controller
#      manager, and a system:masters user must be admitted;
#   3. a person, a ServiceAccount in `default`, one in a namespace that merely
#      looks like ours (tockmox-evil, argocd-evil), system:anonymous and a user
#      in an arbitrary group must be REFUSED;
#   4. the site's extra exemptions (a namespace, a username, a group) admit exactly
#      what they name and nothing else;
#   5. the shipping posture: the guard is off by default, its default binding never
#      says Deny, failurePolicy is Ignore, it matches CREATE of namespaced objects
#      in namespaces labelled tockmox.com/managed-by=tockmox and nothing wider.
#
# WHAT IT DOES NOT PROVE. That a real API server evaluates the expression the way
# cel-python does (the operators used are CEL's standard ones: startsWith, exists,
# in, has, string equality), that Argo CD syncs cleanly with the guard on, or that
# your cluster has no controller this list lacks. That last one is what Warn is
# for; the lab run is a separate clause.
#
# EXIT 2 IS SKIPPED, the repository's convention: helm, python3, PyYAML or
# cel-python missing. A partial run is never a pass. CI installs cel-python
# (`python3 -m pip install cel-python==0.1.5`) in the check-all workflow.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

command -v helm >/dev/null 2>&1 || { echo "check-namespace-guard: helm missing" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-namespace-guard: python3 missing" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "check-namespace-guard: python3 PyYAML missing" >&2; exit 2; }
python3 -c 'import celpy' 2>/dev/null || { echo "check-namespace-guard: cel-python missing (python3 -m pip install cel-python==0.1.5)" >&2; exit 2; }

# Must match dest_ns() in install/tockmox-install.sh (same map as
# check-pod-security.sh and check-no-ghost-policies.sh).
render_ns() {
  case "$1" in
    tockmox-ai)                              echo tockmox-ai ;;
    tockmox-observability|tockmox-exporters) echo tockmox-monitoring ;;
    tockmox-platform)                        echo tockmox-platform ;;
    tockmox-identity)                        echo tockmox-authentik ;;
    tockmox-devops)                          echo tockmox-devops ;;
    tockmox-selfcheck)                       echo tockmox-selfcheck ;;
    *)                                       echo argocd ;;
  esac
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# render_all DIR : every layer, CI defaults ("stock") and the all-on overlay.
render_all() {
  local d="$1" c n ns pass
  mkdir -p "$d"
  for c in charts/tockmox-*; do
    n=$(basename "$c"); [ "$n" = "tockmox-common" ] && continue
    ns=$(render_ns "$n")
    for pass in stock allon; do
      if [ "$pass" = stock ]; then
        helm template t "$c" -n "$ns" -f ci/values.yaml > "$d/${pass}_$n.yaml" || return 1
      else
        helm template t "$c" -n "$ns" -f ci/values.yaml -f ci/values-all-on.yaml > "$d/${pass}_$n.yaml" || return 1
      fi
      printf '%s\n' "$ns" > "$d/${pass}_$n.ns"
    done
  done
}

# policy_render OUT [helm args...] : the policy layer alone, guard switched on by the all-on overlay.
policy_render() {
  local out="$1"; shift
  helm template t charts/tockmox-policy -n argocd -f ci/values.yaml -f ci/values-all-on.yaml "$@" > "$out"
}

# collect_ids RENDER_DIR : write RENDER_DIR/ids.json, every ServiceAccount the layers create or
# bind as [namespace, name, [render files]]. Parsing the renders is most of the run time, so it is done once.
collect_ids() {
  python3 - "$1" <<'PY'
import collections, glob, json, sys
import yaml
renders = sys.argv[1]
ids = collections.defaultdict(set)
for f in sorted(glob.glob(renders + "/*.yaml")):
    rns = open(f[:-5] + ".ns").read().strip()
    for d in yaml.load_all(open(f), Loader=yaml.BaseLoader):
        if not isinstance(d, dict): continue
        k, m = d.get("kind"), d.get("metadata") or {}
        if k == "ServiceAccount":
            ids[(m.get("namespace") or rns, m["name"])].add(f.rsplit("/", 1)[1])
        elif k in ("RoleBinding", "ClusterRoleBinding"):
            for s in d.get("subjects") or []:
                if s.get("kind") == "ServiceAccount":
                    ids[(s.get("namespace") or m.get("namespace") or rns, s["name"])].add(f.rsplit("/", 1)[1])
json.dump([[ns, n, sorted(w)] for (ns, n), w in sorted(ids.items())], open(renders + "/ids.json", "w"))
PY
}

# evaluate RENDER_DIR POLICY_RENDER : run the identity table. Findings on stdout; 1 on any.
evaluate() {
  python3 - "$1" "$2" <<'PY'
import collections, glob, json, sys
import yaml, celpy

renders, policy_file = sys.argv[1], sys.argv[2]
findings = []
def bad(m): findings.append(m)

def load(path):
    return [d for d in yaml.load_all(open(path), Loader=yaml.BaseLoader) if isinstance(d, dict)]

docs = load(policy_file)
vap = next((d for d in docs if d.get("kind") == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == "tockmox-namespace-guard"), None)
vapb = next((d for d in docs if d.get("kind") == "ValidatingAdmissionPolicyBinding" and d["metadata"]["name"] == "tockmox-namespace-guard"), None)
if not vap or not vapb:
    print("tockmox-namespace-guard is not rendered with apps.namespace_guard on (ci/values-all-on.yaml turns it on)"); sys.exit(1)

spec = vap["spec"]
# 5. posture
rules = spec["matchConstraints"]["resourceRules"]
if len(rules) != 1 or rules[0].get("operations") != ["CREATE"] or rules[0].get("scope") != "Namespaced":
    bad("matchConstraints must be one rule: CREATE, scope Namespaced (found %r)" % (rules,))
sel = spec["matchConstraints"].get("namespaceSelector", {}).get("matchLabels")
if sel != {"tockmox.com/managed-by": "tockmox"}:
    bad("namespaceSelector must be exactly tockmox.com/managed-by=tockmox, found %r" % (sel,))
if spec.get("failurePolicy") != "Ignore":
    bad("failurePolicy must ship Ignore (an evaluation error never blocks a request), found %r" % (spec.get("failurePolicy"),))
acts = yaml.safe_load(vapb["spec"]["validationActions"]) if isinstance(vapb["spec"]["validationActions"], str) else vapb["spec"]["validationActions"]
if "Deny" in acts:
    bad("the default binding must not Deny (it ships in Warn), found %r" % (acts,))
if vapb["spec"]["policyName"] != "tockmox-namespace-guard":
    bad("the binding names policy %r" % (vapb["spec"]["policyName"],))
conds = spec.get("matchConditions") or []
if len(conds) != 1 or conds[0]["name"] != "not-gitops-or-platform":
    bad("expected exactly one matchCondition, not-gitops-or-platform; the exemption list must stay in one place")
    print("\n".join(findings)); sys.exit(1)
expr = conds[0]["expression"]
if not any(v.get("expression") == "false" for v in spec.get("validations") or []):
    bad("the validation must be `false` (every request that survives the matchCondition is refused)")

env = celpy.Environment()
prg = env.program(env.compile(expr))
def refused(user, groups=None):
    """True when the guard would refuse this requester: the matchCondition is true."""
    ui = {"username": user}
    if groups is not None: ui["groups"] = groups
    return bool(prg.evaluate(celpy.json_to_cel({"request": {"userInfo": ui}})))

def sa(ns, name): return "system:serviceaccount:%s:%s" % (ns, name)

# 1. every ServiceAccount the product ships (collected once by collect_ids, which
#    reads the renders; the table is the same for every policy variant a selftest tries)
ids = collections.defaultdict(set)
for ns, name, where in json.load(open(renders + "/ids.json")):
    ids[(ns, name)].update(where)
if len(ids) < 40:
    bad("only %d ServiceAccounts found across the layers; the render is not complete enough to trust" % len(ids))
for (ns, name), where in sorted(ids.items()):
    if refused(sa(ns, name)):
        bad("a shipped ServiceAccount would be REFUSED: %s (%s). Its namespace is not in the guard's derived list" % (sa(ns, name), sorted(where)[0]))

# 2. admitted
for who in [sa("argocd", "argocd-application-controller"), sa("kube-system", "replicaset-controller"),
            sa("kube-system", "helm-install-anything"), "system:node:worker-1", "system:kube-controller-manager",
            "system:kube-scheduler", "system:apiserver"]:
    if refused(who): bad("must be ADMITTED but is refused: %s" % who)
if refused("alice", ["system:masters", "system:authenticated"]):
    bad("a user in group system:masters must be ADMITTED (break-glass)")

# 3. refused
for who, groups in [("alice", ["system:authenticated"]), ("alice", None), (sa("default", "builder"), None),
                    (sa("tockmox-evil", "x"), None), (sa("argocd-evil", "x"), None), (sa("kube-system-evil", "x"), None),
                    ("system:anonymous", ["system:unauthenticated"]), ("bob", ["developers", "system:authenticated"]),
                    (sa("trivy-system", "trivy-operator"), None)]:
    if not refused(who, groups): bad("must be REFUSED but is admitted: %s %s" % (who, groups or ""))

# 4. extras, from a second render
extra = glob.glob(renders + "/extra.policy.render")
if extra:
    ex = next((d for d in load(extra[0]) if d.get("kind") == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == "tockmox-namespace-guard"), None)
    if not ex:
        bad("the render with extra exemptions has no guard")
    else:
        p2 = env.program(env.compile(ex["spec"]["matchConditions"][0]["expression"]))
        def ref2(user, groups=None):
            ui = {"username": user}
            if groups is not None: ui["groups"] = groups
            return bool(p2.evaluate(celpy.json_to_cel({"request": {"userInfo": ui}})))
        for who, groups, want, why in [
            (sa("trivy-system", "trivy-operator"), None, False, "an extra exempt namespace admits its ServiceAccounts"),
            (sa("trivy-system-evil", "x"), None, True, "an extra exempt namespace admits only that name, not a lookalike"),
            ("system:serviceaccount:restore-drill:drill", None, False, "an extra exempt user is admitted"),
            ("system:serviceaccount:restore-drill:other", None, True, "an extra exempt user admits only that username"),
            ("carol", ["platform-admins"], False, "an extra exempt group is admitted"),
            ("carol", ["other"], True, "a group that is not named is still refused"),
            (sa("argocd", "argocd-application-controller"), None, False, "the derived list is still there with extras set"),
            (sa("default", "builder"), None, True, "extras do not widen anything else"),
        ]:
            if ref2(who, groups) != want:
                bad("with extras: %s (%s %s)" % (why, who, groups or ""))
else:
    bad("internal: the extras render is missing")

print("\n".join(findings))
sys.exit(1 if findings else 0)
PY
}

# static_defaults : off by default, Warn when on, in values.yaml.
static_defaults() {
  python3 - <<'PY'
import sys, yaml
v = yaml.safe_load(open("charts/tockmox-policy/values.yaml"))
bad = []
if (v.get("apps", {}).get("namespace_guard") or {}).get("enabled") is not False:
    bad.append("apps.namespace_guard.enabled must ship false (off by default), found %r" % ((v.get("apps", {}).get("namespace_guard") or {}).get("enabled"),))
ng = v.get("namespaceGuard") or {}
if "Deny" in (ng.get("validationActions") or []):
    bad.append("namespaceGuard.validationActions must not ship Deny, found %r" % (ng.get("validationActions"),))
if not ng.get("validationActions"):
    bad.append("namespaceGuard.validationActions must name Warn and/or Audit")
if ng.get("failurePolicy") != "Ignore":
    bad.append("namespaceGuard.failurePolicy must ship Ignore, found %r" % (ng.get("failurePolicy"),))
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
}

# run_checks DIR POLICY_FILE : everything, against already-rendered inputs.
run_checks() {
  local rc=0 out
  out=$(static_defaults) || { echo "$out"; rc=1; }
  collect_ids "$1" || { echo "check-namespace-guard: could not read the renders"; return 1; }
  out=$(evaluate "$1" "$2") || { echo "$out"; rc=1; }
  return $rc
}

selftest() {
  local T n=0 failed=0
  T="$(mktemp -d)"
  trap 'rm -rf "$work" "$T"' RETURN
  render_all "$T/r" || { echo "selftest: the layers do not render"; return 1; }
  collect_ids "$T/r" || return 1
  policy_render "$T/policy.yaml" || return 1
  policy_render "$T/r/extra.policy.render" \
    --set-json 'namespaceGuard.extraExemptServiceAccountNamespaces=["trivy-system"]' \
    --set-json 'namespaceGuard.extraExemptUsers=["system:serviceaccount:restore-drill:drill"]' \
    --set-json 'namespaceGuard.extraExemptGroups=["platform-admins"]' || return 1
  expect() {  # label want(red|green) needle policy-file [renders-dir]
    local out r
    out="$(evaluate "${5:-$T/r}" "$4" 2>&1)"; r=$?
    n=$((n + 1))
    if [ "$2" = green ] && [ "$r" -eq 0 ]; then printf '  green %s\n'  "$1"
    elif [ "$2" = red ] && [ "$r" -eq 1 ] && printf '%s' "$out" | grep -F -- "$3" >/dev/null; then printf '  red   %s\n' "$1"
    else printf '  WRONG %s (wanted %s containing "%s", rc=%s)\n%s\n' "$1" "$2" "$3" "$r" "$out" | head -6; failed=$((failed + 1)); fi
  }
  mutate() {  # name python-expression-on-s : write $T/<name>.yaml from the good render
    python3 - "$T/policy.yaml" "$T/$1.yaml" "$2" <<'PY'
import sys
# Only the guard's own objects are mutated: the same text (failurePolicy: Ignore, a namespace
# name) also appears in other policies and in alert rules earlier in the render.
head, sep, s = open(sys.argv[1]).read().partition("# Source: tockmox-policy/templates/namespace-guard.yaml")
assert sep, "the render has no namespace-guard template"
before = s
exec(sys.argv[3])
assert s != before, "the mutation changed nothing"
open(sys.argv[2], "w").write(head + sep + s)
PY
  }
  expect "the unmodified render is green" green "" "$T/policy.yaml"
  mutate m1 's = s.replace("\"argocd\",", "", 1)'
  expect "Argo CD dropped from the trusted namespaces" red "argocd" "$T/m1.yaml"
  mutate m2 's = s.replace("\"kube-system\",", "", 1)'
  expect "kube-system dropped from the trusted namespaces" red "kube-system" "$T/m2.yaml"
  mutate m3 's = s.replace("\"tockmox-platform\",", "", 1)'
  expect "a layer namespace dropped (a shipped ServiceAccount would be refused)" red "a shipped ServiceAccount would be REFUSED" "$T/m3.yaml"
  mutate m4 's = s.replace("[\"system:masters\"].exists(g, g in request.userInfo.groups)", "false")'
  expect "system:masters no longer admitted" red "system:masters" "$T/m4.yaml"
  mutate m5 's = s.replace("request.userInfo.username != '"'"'system:anonymous'"'"'", "true")'
  expect "system:anonymous admitted through the system: clause" red "system:anonymous" "$T/m5.yaml"
  mutate m6 's = s.replace("'"'"'system:serviceaccount:'"'"' + n + '"'"':'"'"'", "'"'"'system:serviceaccount:'"'"' + n")'
  expect "the trailing colon dropped (a lookalike namespace is admitted)" red "must be REFUSED" "$T/m6.yaml"
  mutate m7 's = s.replace("startsWith(\x27system:serviceaccount:\x27 + n", "startsWith(\x27system:serviceaccount:tockmox-\x27 + n[0:0]", 1)'
  expect "the exemption turned into a tockmox- prefix match" red "" "$T/m7.yaml"
  mutate m8 's = s.replace("validationActions: [\"Audit\",\"Warn\"]", "validationActions: [\"Deny\"]")'
  expect "the default binding set to Deny" red "must not Deny" "$T/m8.yaml"
  mutate m9 's = s.replace("tockmox.com/managed-by: tockmox\n  matchConditions", "tockmox.com/managed-by: other\n  matchConditions")'
  expect "the namespace selector widened or changed" red "namespaceSelector" "$T/m9.yaml"
  mutate m10 's = s.replace("operations: [\"CREATE\"]\n        resources: [\"*\"]\n        scope: Namespaced", "operations: [\"CREATE\", \"UPDATE\"]\n        resources: [\"*\"]\n        scope: Namespaced")'
  expect "UPDATE added to the matched operations" red "matchConstraints" "$T/m10.yaml"
  mutate m11 's = s.replace("failurePolicy: Ignore", "failurePolicy: Fail", 1)'
  expect "failurePolicy flipped to Fail" red "failurePolicy" "$T/m11.yaml"
  # extras: render with the extras removed, as if the template ignored them
  mkdir -p "$T/r2"; cp -r "$T/r"/. "$T/r2"/; cp "$T/policy.yaml" "$T/r2/extra.policy.render"
  expect "the extra exemptions ignored by the template" red "with extras" "$T/policy.yaml" "$T/r2"
  # defaults in values.yaml
  mkdir -p "$T/v/charts/tockmox-policy"
  for variant in on deny fail; do
    cp charts/tockmox-policy/values.yaml "$T/v/charts/tockmox-policy/values.yaml"
    case "$variant" in
      on)   sed -i.bak 's/^  namespace_guard:   { enabled: false }/  namespace_guard:   { enabled: true }/' "$T/v/charts/tockmox-policy/values.yaml"; want="ship false" ;;
      deny) sed -i.bak 's/^  validationActions: \["Audit", "Warn"\]/  validationActions: ["Deny"]/' "$T/v/charts/tockmox-policy/values.yaml"; want="must not ship Deny" ;;
      fail) sed -i.bak '/^namespaceGuard:/,/^  extraExemptGroups/ s/failurePolicy: Ignore/failurePolicy: Fail/' "$T/v/charts/tockmox-policy/values.yaml"; want="must ship Ignore" ;;
    esac
    out="$(cd "$T/v" && static_defaults 2>&1)"; r=$?
    n=$((n + 1))
    if [ "$r" -eq 1 ] && printf '%s' "$out" | grep -F -- "$want" >/dev/null; then printf '  red   values.yaml default planted: %s\n' "$variant"
    else printf '  WRONG values.yaml default planted: %s (rc=%s)\n%s\n' "$variant" "$r" "$out"; failed=$((failed + 1)); fi
  done
  if [ "$failed" -ne 0 ]; then echo "check-namespace-guard --selftest: $failed of $n expectations wrong"; return 1; fi
  echo "check-namespace-guard --selftest: $n expectations met (every rule goes red on its planted defect)"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac

render_all "$work/r" || { echo "check-namespace-guard: a layer did not render" >&2; exit 1; }
policy_render "$work/policy.yaml" || { echo "check-namespace-guard: the policy layer did not render" >&2; exit 1; }
policy_render "$work/r/extra.policy.render" \
  --set-json 'namespaceGuard.extraExemptServiceAccountNamespaces=["trivy-system"]' \
  --set-json 'namespaceGuard.extraExemptUsers=["system:serviceaccount:restore-drill:drill"]' \
  --set-json 'namespaceGuard.extraExemptGroups=["platform-admins"]' || exit 1
if run_checks "$work/r" "$work/policy.yaml"; then
  echo "namespace guard: every shipped ServiceAccount is admitted, the expected identities are refused, extras admit only what they name"
else
  exit 1
fi

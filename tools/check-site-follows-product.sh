#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A product bump of Open WebUI or LiteLLM reaches a site with no site edit
# (TM-1053). Asserted ON THE RENDERED ARTIFACT, because each of these renders
# clean when it is wrong.
#
#   ./tools/check-site-follows-product.sh             run the assertions
#   ./tools/check-site-follows-product.sh --selftest  prove each can go red
#
# WHY. On 2026-10-17 the homelab pinned both applications' tags in its own values
# because it restated an initContainer that names the image, and the chart
# requires that image to equal the application's. Open WebUI 0.12.3 and LiteLLM
# 1.105.1 were two pull requests each, product and site, and the site sat a week
# behind. The chart now gives a site nothing to restate, and refuses the part of
# it that is still restatable when it is wrong.
#
# S1  Open WebUI, SSO off, global.certIssuer set (the homelab): the trust-bundle
#     initContainer reads TOCKMOX_EXPECT_CA from a ConfigMap that renders without
#     SSO, the ConfigMap says "true", the container's envFrom reads it AFTER the
#     SSO Secret, and its image is the application's image. With certIssuer empty
#     it says "false"; modelGateway.trustBundle.expectCA overrides either way.
# S2  LiteLLM, a build-ca-bundle initContainer written with the tpl idiom and no
#     litellm.image.tag anywhere: the Deployment's and the migrations Job's init
#     images equal their own application images, and still do after the tag moves
#     (a product bump, with no site edit).
# S3  A build-ca-bundle initContainer whose image is not the application's is
#     refused, in either list, with a sentence that names the idiom; a literal
#     that happens to equal the application's is accepted.
# S4  Moving only Open WebUI's application tag is still refused (the existing
#     guard stays), so the two lines the product moves together cannot drift.
set -euo pipefail
cd "$(dirname "$0")/.."

CH=${CH:-charts/tockmox-ai}
VALUES=${VALUES:-ci/values.yaml}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
bad=0
fail() { echo "FAIL $*"; bad=1; }
pass() { echo "  ok $*"; }

IDIOM='{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}'
site_ca() { # site_ca <image string>: a site that restates the LiteLLM CA step in both lists
  cat <<YAML
litellm:
  extraInitContainers: &ca
    - name: build-ca-bundle
      image: "$1"
      command: ["/bin/sh", "-c"]
      args: ["true"]
  migrationJob:
    extraInitContainers: *ca
YAML
}

render() { # render <out> [helm args]; the chart under test is \$CH
  local out="$1"; shift
  helm template t "$CH" -f "$VALUES" "$@" > "$out" 2> "${out%.yaml}.err"
}

if [ "${1:-}" != "--selftest" ]; then
  command -v helm >/dev/null || { echo "check-site-follows-product: helm missing" >&2; exit 2; }

  # ---- S1 ----
  render "$tmp/s1.yaml" --set sso.enabled=false --set global.certIssuer=private-ca-issuer \
    || { fail "S1: the chart does not render with SSO off: $(head -3 "$tmp/s1.err")"; }
  python3 - "$tmp/s1.yaml" <<'PY' || bad=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
cm = [d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tockmox-ai-trust-env"]
sts = [d for d in docs if d.get("kind") in ("StatefulSet", "Deployment") and
       any(c["name"] == "open-webui" for c in d["spec"]["template"]["spec"]["containers"])]
rc = 0
if len(cm) != 1:
    print("FAIL S1: no tockmox-ai-trust-env ConfigMap with SSO off: the trust-bundle initContainer cannot learn that a CA is coming, which is why a site restated it"); rc = 1
elif cm[0]["data"].get("TOCKMOX_EXPECT_CA") != "true":
    print("FAIL S1: certIssuer is set but the ConfigMap says TOCKMOX_EXPECT_CA=%r" % cm[0]["data"].get("TOCKMOX_EXPECT_CA")); rc = 1
if len(sts) != 1:
    print("FAIL S1: want one Open WebUI workload, found %d" % len(sts)); rc = 1
else:
    sp = sts[0]["spec"]["template"]["spec"]
    main = [c for c in sp["containers"] if c["name"] == "open-webui"][0]
    init = [c for c in sp.get("initContainers", []) if c["name"] == "tockmox-trust-bundle"]
    if not init:
        print("FAIL S1: no tockmox-trust-bundle initContainer"); rc = 1
    else:
        init = init[0]
        refs = [("secret", e["secretRef"]["name"]) if "secretRef" in e else ("configmap", e["configMapRef"]["name"]) for e in init.get("envFrom", [])]
        if ("configmap", "tockmox-ai-trust-env") not in refs:
            print("FAIL S1: the initContainer does not read tockmox-ai-trust-env (envFrom: %r)" % refs); rc = 1
        elif ("secret", "tockmox-ai-sso-env") in refs and refs.index(("configmap", "tockmox-ai-trust-env")) < refs.index(("secret", "tockmox-ai-sso-env")):
            print("FAIL S1: the ConfigMap is read BEFORE the SSO Secret, so the Secret wins and modelGateway.trustBundle.expectCA cannot override it"); rc = 1
        if init["image"] != main["image"]:
            print("FAIL S1: initContainer image %r != application image %r" % (init["image"], main["image"])); rc = 1
if rc == 0:
    print("  ok S1: SSO off, certIssuer set: TOCKMOX_EXPECT_CA=true reaches the trust-bundle initContainer from a ConfigMap read after the Secret, on the application's image")
sys.exit(rc)
PY
  expect_ca() { # expect_ca <want> <label> [helm args]
    local want="$1" label="$2"; shift 2
    if ! render "$tmp/e.yaml" "$@"; then fail "S1: $label: does not render: $(head -3 "$tmp/e.err")"; return; fi
    local got
    got=$(python3 - "$tmp/e.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if isinstance(d, dict) and d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tockmox-ai-trust-env":
        print(d["data"]["TOCKMOX_EXPECT_CA"]); break
else:
    print("absent")
PY
)
    if [ "$got" = "$want" ]; then pass "S1: $label: TOCKMOX_EXPECT_CA=$want"; else fail "S1: $label: TOCKMOX_EXPECT_CA is $got, want $want"; fi
  }
  expect_ca false "certIssuer empty follows to false" --set global.certIssuer=
  expect_ca true  "certIssuer empty, expectCA true" --set global.certIssuer= --set modelGateway.trustBundle.expectCA=true
  expect_ca false "certIssuer set, expectCA false" --set global.certIssuer=private-ca-issuer --set modelGateway.trustBundle.expectCA=false

  # ---- S2 ----
  site_ca "$IDIOM" > "$tmp/idiom.yaml"
  lit_inits() { # lit_inits <rendered file>: "<workload kind/name> <init image> <app image>" per LiteLLM pod with a build-ca-bundle
    python3 - "$1" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not isinstance(d, dict): continue
    sp = (d.get("spec") or {}).get("template", {}).get("spec")
    if not isinstance(sp, dict): continue
    for i in sp.get("initContainers") or []:
        if i["name"] == "build-ca-bundle":
            main = sp["containers"][0]
            print(d["kind"], i["image"], main["image"])
PY
  }
  for tag in "" "9.9.9"; do
    if [ -n "$tag" ]; then set -- --set litellm.image.tag="$tag"; else set -- ; fi
    if ! render "$tmp/s2.yaml" -f "$tmp/idiom.yaml" "$@"; then fail "S2: the tpl idiom does not render (tag '${tag:-default}'): $(head -3 "$tmp/s2.err")"; continue; fi
    out=$(lit_inits "$tmp/s2.yaml")
    n=$(printf '%s\n' "$out" | grep -c . || true)
    if [ "$n" != 2 ]; then fail "S2: want a build-ca-bundle on the Deployment and on the migrations Job, found $n (tag '${tag:-default}')"; continue; fi
    printf '%s\n' "$out" | while read -r kind init app; do
      [ "$init" = "$app" ] || { echo "FAIL S2: $kind: build-ca-bundle image $init != application image $app (tag '${tag:-default}')"; exit 1; }
    done || bad=1
    if [ -n "$tag" ]; then
      case "$out" in
        *":$tag "*) pass "S2: after litellm.image.tag=$tag both init images followed, with no tag in the site's values" ;;
        *) fail "S2: litellm.image.tag=$tag did not reach the init images" ;;
      esac
    fi
    [ -n "$tag" ] || pass "S2: the tpl idiom gives the Deployment's and the Job's build-ca-bundle the application's image with litellm.image.tag unset"
  done

  # ---- S3 ----
  site_ca "ghcr.io/berriai/litellm-database:1.0.0" > "$tmp/lit.yaml"
  if render "$tmp/s3.yaml" -f "$tmp/lit.yaml"; then fail "S3: a build-ca-bundle on a different image rendered"
  elif grep -q "build-ca-bundle\].image resolves to" "$tmp/s3.err" && grep -q "Chart.AppVersion" "$tmp/s3.err"; then pass "S3: a build-ca-bundle on another image is refused, naming the idiom"
  else fail "S3: refused, but not with the sentence that names the image and the idiom: $(head -2 "$tmp/s3.err" | cut -c1-300)"; fi
  python3 - "$tmp/lit.yaml" "$tmp/lit-mig.yaml" <<'PY'
import sys, re
t = open(sys.argv[1]).read()
# The Deployment's list right, the migrations Job's list wrong: *ca becomes its own mapping.
t = t.replace("    extraInitContainers: *ca", "    extraInitContainers:\n      - name: build-ca-bundle\n        image: \"ghcr.io/berriai/litellm-database:1.0.0\"\n        command: [\"/bin/sh\", \"-c\"]\n        args: [\"true\"]")
t = t.replace('image: "ghcr.io/berriai/litellm-database:1.0.0"\n      command', 'image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"\n      command', 1)
open(sys.argv[2], "w").write(t)
PY
  if render "$tmp/s3b.yaml" -f "$tmp/lit-mig.yaml"; then fail "S3: a wrong image in litellm.migrationJob.extraInitContainers alone rendered"
  elif grep -q "migrationJob.extraInitContainers\[build-ca-bundle\]" "$tmp/s3b.err"; then pass "S3: a wrong image in the migrations Job's list alone is refused"
  else fail "S3: the migrations Job's list was not checked: $(head -2 "$tmp/s3b.err" | cut -c1-300)"; fi
  # a literal equal to the application's image
  render "$tmp/plain.yaml" || fail "S3: the stock chart does not render"
  want=$(python3 - "$tmp/plain.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    sp = isinstance(d, dict) and (d.get("spec") or {}).get("template", {}).get("spec")
    if sp and sp["containers"][0]["name"] == "litellm": print(sp["containers"][0]["image"]); break
PY
)
  site_ca "$want" > "$tmp/lit-eq.yaml"
  if render "$tmp/s3c.yaml" -f "$tmp/lit-eq.yaml"; then pass "S3: a literal equal to the application's image is accepted"; else fail "S3: a literal equal to the application's image ($want) was refused: $(head -2 "$tmp/s3c.err" | cut -c1-300)"; fi

  # ---- S4 ----
  if render "$tmp/s4.yaml" --set open-webui.image.tag=9.9.9; then fail "S4: moving only Open WebUI's application tag rendered"
  elif grep -q "trust-bundle initContainer image mismatch" "$tmp/s4.err"; then pass "S4: moving only Open WebUI's application tag is refused"
  else fail "S4: refused, but not by the image-mismatch guard: $(head -2 "$tmp/s4.err" | cut -c1-300)"; fi

  [ "$bad" = 0 ] || { echo "check-site-follows-product: FAILED"; exit 1; }
  echo "check-site-follows-product: ok"
  exit 0
fi

# ---------------------------------------------------------------------------
# --selftest: copy the chart, break one thing, expect the assertions to go red.
# ---------------------------------------------------------------------------
mutant() { # mutant <name> <file under the chart> <python expression over s>
  local name="$1" file="$2" expr="$3" d="$tmp/m.$1"
  mkdir -p "$d"; cp -R charts/tockmox-ai "$d/tockmox-ai"
  # tockmox-common is a file:// dependency that is already packed in charts/, so the copy renders alone.
  python3 - "$d/tockmox-ai/$file" "$expr" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p).read()
n = eval(expr)
if n == s:
    print("selftest FAIL: the mutation '%s' changed nothing" % expr); sys.exit(1)
open(p, "w").write(n)
PY
  if CH="$d/tockmox-ai" bash "$0" > "$d/out" 2>&1; then
    echo "selftest FAIL: $name: the gate passed"; bad=1
  else
    echo "selftest ok: the gate goes red when $name"
  fi
}
mutant "the ConfigMap is not rendered without SSO" templates/trust-env.yaml 's.replace("include \"tockmox.appEnabled\" (dict \"ctx\" $ \"app\" \"openWebui\")", "and (include \"tockmox.appEnabled\" (dict \"ctx\" $ \"app\" \"openWebui\")) .Values.sso.enabled")'
mutant "the ConfigMap ignores global.certIssuer" templates/trust-env.yaml 's.replace("{{- $expect := ne (.Values.global.certIssuer | default \"\") \"\" -}}", "{{- $expect := true -}}")'
mutant "the override is ignored" templates/trust-env.yaml 's.replace("{{- if kindIs \"bool\" $tb.expectCA }}{{- $expect = $tb.expectCA }}{{- end }}", "")'
mutant "the initContainer stops reading the ConfigMap" values.yaml 's.replace("        - configMapRef:\n            name: tockmox-ai-trust-env\n            optional: true\n", "")'
mutant "the ConfigMap is read before the Secret" values.yaml 's.replace("        - secretRef:\n            name: tockmox-ai-sso-env\n            optional: true\n        # AFTER the Secret", "        - configMapRef:\n            name: tockmox-ai-trust-env\n            optional: true\n        - secretRef:\n            name: tockmox-ai-sso-env\n            optional: true\n        # AFTER the Secret", 1).replace("        - configMapRef:\n            name: tockmox-ai-trust-env\n            optional: true\n      command", "      command", 1)'
mutant "the LiteLLM image check is gone" templates/preflight.yaml 's.replace("{{- if ne $lgot $lwant -}}", "{{- if false -}}")'
mutant "the LiteLLM check skips the migrations Job's list" templates/preflight.yaml 's.replace("\"litellm.migrationJob.extraInitContainers\" ((($lv.migrationJob | default dict).extraInitContainers) | default list)", "\"litellm.migrationJob.extraInitContainers\" list")'
mutant "the Open WebUI image guard is gone" templates/preflight.yaml 's.replace("\"actual\" $initImage)", "\"actual\" (printf \"%s:%s\" $img.repository $tag))")'
[ "$bad" = 0 ] || exit 1
echo "check-site-follows-product selftest: ok"

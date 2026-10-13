#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assert that every Ingress this chart set renders terminates TLS.
#
#   ./tools/check-ingress-tls.sh              # both value sets
#   ./tools/check-ingress-tls.sh --selftest   # prove it can go red
#
# WHY THIS EXISTS, and it is a measurement rather than a policy preference.
#
# The web entrypoint redirects to websecure by default (TM-0558). That is the
# right default and it has a prerequisite the redirect itself cannot check: a
# host with no certificate does NOT fail politely when it is redirected.
# Traefik answers on :443 anyway, with its own self-signed
# `CN=TRAEFIK DEFAULT CERT`, so the user meets a browser interstitial instead of
# the application.
#
# Observed on the reference lab 2026-09-13. The devtest site's `news` Ingress
# was the only one of seven hosts with no `tls:` block:
#
#   news.int.example.com     subject=CN=TRAEFIK DEFAULT CERT  (self-signed)
#   grafana.int.example.com  issuer=CN=Tockmox local CA
#
# Over http it worked and nobody noticed for a month. The moment a redirect
# lands, that host is broken for every user, and the failure looks like a
# certificate problem rather than a missing field three repos away.
#
# SO THE GATE ASSERTS THE PRECONDITION, NOT THE REDIRECT. A red result means an
# Ingress needs a `tls:` block and an issuer annotation, never that the redirect
# should be turned off.
#
# SCOPE, stated so nobody widens it by accident: this checks what the CHARTS
# render. A site's own `apps/` manifests are outside it ... which is exactly
# where the `news` case lived, so this gate would NOT have caught that one. That
# limit is real and is recorded rather than papered over;
# `adding-an-application.md` carries the same requirement for site-authored
# Ingresses.
#
#   exit 0  every rendered Ingress terminates TLS
#   exit 1  at least one does not, or the run examined nothing
#   exit 2  could not run: no helm, no python, no PyYAML
set -euo pipefail
cd "$(dirname "$0")/.."

HELM="${HELM:-helm}"
PY="${PYTHON:-python3}"
PARSER="tools/lib/ingress_tls.py"

command -v "$HELM" >/dev/null 2>&1 || { echo "check-ingress-tls: SKIPPED ... no helm on PATH"; exit 2; }
command -v "$PY"   >/dev/null 2>&1 || { echo "check-ingress-tls: SKIPPED ... no python3 on PATH"; exit 2; }
"$PY" -c "import yaml" 2>/dev/null || { echo "check-ingress-tls: SKIPPED ... PyYAML not installed"; exit 2; }
[ -f "$PARSER" ] || { echo "check-ingress-tls: SKIPPED ... $PARSER is missing"; exit 2; }

CI_VALUES="ci/values.yaml"
ALL_ON="ci/values-all-on.yaml"

fail=0
grand_total=0

check_pass() {
  local label="$1"; shift
  local vflags=() f
  for f in "$@"; do [ -f "$f" ] && vflags+=(-f "$f"); done

  echo "== pass: $label"
  local found=0 bad=0 chart rendered out n

  for chart in charts/tockmox-*/; do
    [ -f "${chart}Chart.yaml" ] || continue
    rendered="$("$HELM" template t "$chart" "${vflags[@]}" 2>/dev/null || true)"
    [ -n "$rendered" ] || continue

    # Parser reads stdin and the SCRIPT comes from a file. Inlining it as
    # `python3 - <<'PY'` makes the heredoc the script and leaves stdin empty,
    # which is how the first version of this gate examined nothing and called
    # itself clean.
    #
    # NO `|| true` HERE, deliberately. The second version had one, so when the
    # parser threw on a chart the traceback was swallowed, that chart was
    # dropped from the count, and the gate still reported clean. A parser that
    # could not read its input must not look like one that found nothing wrong.
    if ! out="$(printf '%s' "$rendered" | "$PY" "$PARSER" 2>&1)"; then
      echo "  FAIL ${chart}: the parser exited non-zero; output follows"
      printf '%s\n' "$out" | sed 's/^/      /'
      bad=$((bad + 1))
      continue
    fi

    n="$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p')"
    [ -n "$n" ] && found=$((found + n))

    while IFS= read -r line; do
      case "$line" in
        BAD\ *) echo "  FAIL ${chart}${line#BAD }  has no tls block"; bad=$((bad + 1)) ;;
        ERR\ *) echo "  FAIL ${chart}: unparseable document ... ${line#ERR }"; bad=$((bad + 1)) ;;
      esac
    done <<EOF
$out
EOF
  done

  grand_total=$((grand_total + found))

  if [ "$bad" -gt 0 ]; then
    echo "  $bad of $found rendered Ingress(es) terminate no TLS"
    return 1
  fi
  echo "  all $found rendered Ingress(es) terminate TLS"
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  echo "== selftest: a tls-less Ingress must be caught"
  res="$(printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: selftest-no-tls\nspec:\n  rules:\n    - host: selftest.example.com\n' \
         | "$PY" "$PARSER" | grep -c '^BAD ' || true)"
  if [ "$res" = "1" ]; then
    echo "  ok ... the tls-less Ingress was detected"
  else
    echo "  FAIL ... it was NOT detected; this gate is decoration"
    exit 1
  fi
  echo "== selftest: a tls-bearing Ingress must NOT be flagged"
  res="$(printf 'apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: selftest-tls\nspec:\n  tls:\n    - hosts: [ok.example.com]\n      secretName: ok-tls\n  rules:\n    - host: ok.example.com\n' \
         | "$PY" "$PARSER" | grep -c '^BAD ' || true)"
  if [ "$res" = "0" ]; then
    echo "  ok ... no false positive"
    exit 0
  fi
  echo "  FAIL ... a compliant Ingress was flagged"
  exit 1
fi

check_pass "ci values (shipped defaults)" "$CI_VALUES" || fail=1
[ -f "$ALL_ON" ] && { check_pass "all-on overlay" "$CI_VALUES" "$ALL_ON" || fail=1; }

echo
# A gate that examined nothing must not report clean. This is the failure the
# first version of this script shipped with: zero Ingresses found, "clean"
# printed, exit 0.
if [ "$grand_total" -eq 0 ]; then
  echo "check-ingress-tls: FAILED ... zero Ingresses were examined."
  echo "  That is not a pass. Either the charts render no Ingress (in which"
  echo "  case this gate needs its value set fixed) or the render failed"
  echo "  silently. Investigate before trusting any green from this file."
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "check-ingress-tls: FAILED"
  echo "  Add a tls block and an issuer annotation to each Ingress named above."
  echo "  Do NOT resolve this by disabling the web->websecure redirect: without"
  echo "  TLS that host serves Traefik's self-signed default certificate either"
  echo "  way, and the redirect is only what makes the gap visible."
  exit 1
fi
echo "check-ingress-tls: clean ($grand_total Ingress(es) checked)"

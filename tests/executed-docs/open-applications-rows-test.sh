#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P14's rows: an unbound Authentik application is listed as open, declaring it open stops the
# warning, and binding it takes it off the list. No cluster. Four layers.
#
#   1. The verdicts (lib/p14-open-applications.py). A green fixture for each, then one planted red per thing the
#      verdict reads, each of which must change the verdict. An empty or unreadable input is never a pass.
#   2. The pages. The three YAML blocks P14 extracts resolve in this tree, blocks B and C name the file P14 writes,
#      and the one edit P14 makes to block A (its bindings taken out) leaves an application and no binding. A page
#      edit that breaks any of these is red here, per commit, not on the next lane run.
#   3. The path as a script, against a stub kubectl and a local bare repository standing in for the site's remote.
#      The stub is the product: what it answers for the list is computed from what the path PUSHED (the blueprint's
#      bindings, sso.access.everyone), so a row is green only when the delivery reached origin. Green end to end,
#      then one broken product per row (it never lists, it ignores the declaration, it ignores the binding, the
#      declaration sticks), each of which must fail the path at that row. Then mutated copies of P14 that lose a
#      guard, each of which must not end PASS.
#   4. The gate: P14 runs after P09 on the external route and must declare BLOCKED, with no cluster call, when
#      P09's state, its PASS marker, its site repository or that repository's remote is missing.
#
#   ./tests/executed-docs/open-applications-rows-test.sh
#   P14=/path/to/P14.sh ./tests/executed-docs/open-applications-rows-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
P14="${P14:-${HERE}/paths/P14-open-applications.sh}"
PY="${HERE}/lib/p14-open-applications.py"
EXTRACT="${HERE}/lib/extract-block.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
v() { python3 -I "$PY" "$@" | head -1; }
is() { # LABEL EXPECTED ACTUAL
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [${2}], got [${3}]"
}
mut() { # IN OUT OLD NEW ... a copy with every OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}

# ------------------------------------------------------------------ 1. the verdicts
# mk_cm FILE REPORT-JSON ... the ConfigMap as kubectl prints it, holding that report
mk_cm() {
  python3 - "$1" "$2" <<'PY'
import json, sys
doc = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "tockmox-identity-open-applications"}}
if sys.argv[2] != "NODATA":
    doc["data"] = {"report.json": sys.argv[2]}
json.dump(doc, open(sys.argv[1], "w"))
PY
}
REP() { printf '{"version": 1, "generatedAt": "2026-11-13T10:00:00Z", "applications": 9, "open": [%s], "everyoneNotFound": []}' "$1"; }
ROW() { printf '{"slug": "%s", "name": "n", "group": "", "everyone": %s}' "$1" "$2"; }
C="${TMP}/cm.json"
mk_cm "$C" "$(REP "$(ROW argocd false)")";  is "listed: an unbound application the site did not declare reads as the warning shape" "listed, not declared open" "$(v listed --slug argocd < "$C")"
mk_cm "$C" "$(REP "$(ROW argocd true)")";   is "listed: the same application declared open reads as declared" "listed, declared open" "$(v listed --slug argocd < "$C")"
mk_cm "$C" "$(REP "$(ROW other false)")";   is "listed: a list that names only another application does not name this one" "not listed" "$(v listed --slug argocd < "$C")"
mk_cm "$C" "$(REP "")";                     is "listed: an empty list names nothing" "not listed" "$(v listed --slug argocd < "$C")"
mk_cm "$C" "$(REP "$(ROW argocd '"yes"')")"; is "listed: everyone must be true itself, a truthy string is not a declaration" "listed, not declared open" "$(v listed --slug argocd < "$C")"
mk_cm "$C" "$(REP "$(ROW argocd false), $(ROW argocd true)")"
case "$(v listed --slug argocd < "$C")" in unreadable*) ok "listed: a slug listed twice is unreadable, not a pick of one" ;; *) bad "listed twice" "$(v listed --slug argocd < "$C")" ;; esac
mk_cm "$C" NODATA
case "$(v listed --slug argocd < "$C")" in unreadable*"has not written"*) ok "listed: a ConfigMap the job never wrote is unreadable, never 'not listed'" ;; *) bad "listed: unwritten" "$(v listed --slug argocd < "$C")" ;; esac
mk_cm "$C" '{"version": 2, "open": []}'
case "$(v listed --slug argocd < "$C")" in unreadable*) ok "listed: another list version is unreadable" ;; *) bad "listed: version" "$(v listed --slug argocd < "$C")" ;; esac
mk_cm "$C" 'not json'
case "$(v listed --slug argocd < "$C")" in unreadable*) ok "listed: a report that is not JSON is unreadable" ;; *) bad "listed: bad report" "$(v listed --slug argocd < "$C")" ;; esac
case "$(: | v listed --slug argocd)" in unreadable*) ok "listed: an empty read (the kubectl call failed) is unreadable, never 'not listed'" ;; *) bad "listed: empty" "$(: | v listed --slug argocd)" ;; esac
case "$(printf '{"kind":"Status","code":404}' | v listed --slug argocd)" in unreadable*) ok "listed: an API error object is unreadable" ;; *) bad "listed: status" "" ;; esac
mk_cm "$C" "$(REP "")"; is "written-at: the list's own time is read" "2026-11-13T10:00:00Z" "$(v written-at < "$C")"

mk_cron() { printf '{"kind":"CronJob","spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"list","env":[{"name":"X","value":"1"}%s]}]}}}}}}' "$1" > "${TMP}/cron.json"; }
mk_cron ',{"name":"TOCKMOX_OPEN_TO_EVERYONE","value":"[]"}';           is "everyone-env: a job that reads no declared slug says []" "[]" "$(v everyone-env < "${TMP}/cron.json")"
mk_cron ',{"name":"TOCKMOX_OPEN_TO_EVERYONE","value":"[\"argocd\"]"}'; is "everyone-env: a job that still reads the declaration says so" '["argocd"]' "$(v everyone-env < "${TMP}/cron.json")"
mk_cron ''
case "$(v everyone-env < "${TMP}/cron.json")" in unreadable*) ok "everyone-env: a CronJob without the variable is unreadable, never []" ;; *) bad "everyone-env: missing" "" ;; esac
case "$(: | v everyone-env)" in unreadable*) ok "everyone-env: an empty read is unreadable, never []" ;; *) bad "everyone-env: empty" "" ;; esac

# ------------------------------------------------------------------ 2. the pages
A="${TMP}/a.yaml"; B="${TMP}/b.yaml"; CC="${TMP}/c.yaml"
bash "$EXTRACT" --file "${TREE}/docs/administration/argocd.md" --section '## A hostname and a portal tile' --lang yaml --containing 'name: argocd-sso-blueprint' > "$A" 2>/dev/null
bash "$EXTRACT" --file "${TREE}/docs/administration/argocd.md" --section '## A hostname and a portal tile' --lang yaml --containing '- argocd-sso-blueprint' > "$B" 2>/dev/null
bash "$EXTRACT" --file "${TREE}/docs/administration/identity.md" --section '## Applications open to every signed-in user' --lang yaml --containing 'everyone:' > "$CC" 2>/dev/null
[ -s "$A" ] && [ -s "$B" ] && [ -s "$CC" ] && ok "pages: the three YAML blocks P14 extracts resolve in this tree, each to one block" || bad "pages: blocks resolve" "A=$(wc -c < "$A") B=$(wc -c < "$B") C=$(wc -c < "$CC") bytes"
is "pages: block A as printed holds one binding present and one stated absent" "1 present, 1 absent" "$(v bindings < "$A")"
grep -q 'slug: argocd$' "$A" && grep -q 'name: tockmox-admins$' "$A" && ok "pages: block A's application is argocd and its group is tockmox-admins, the names P14 asserts on" || bad "pages: block A names" ""
is "pages: blocks B and C say in their first line which file they belong in" "# site/values/identity.yaml # site/values/identity.yaml" "$(head -1 "$B") $(head -1 "$CC")"
grep -q '^ *- handbook\( \|$\)' "$CC" && ok "pages: block C's example slug is the one P14 substitutes" || bad "pages: block C example slug" "$(cat "$CC")"
python3 -I "$PY" unbind < "$A" > "${TMP}/unbound.yaml"; urc=$?
is "unbind: block A with its bindings taken out holds none" "0 0 present, 0 absent" "${urc} $(v bindings < "${TMP}/unbound.yaml")"
grep -q 'model: authentik_core.application' "${TMP}/unbound.yaml" && grep -q 'model: authentik_providers_oauth2.oauth2provider' "${TMP}/unbound.yaml" \
  && [ "$(grep -c 'model: authentik_core.group' "${TMP}/unbound.yaml")" = 2 ] && ok "unbind: the application, its provider and both groups are still there" || bad "unbind: what is left" "$(grep -c model: "${TMP}/unbound.yaml") entries"
[ -z "$(diff <(grep -v . /dev/null; cat "$A") "${TMP}/unbound.yaml" | grep '^>')" ] && ok "unbind: nothing is added or rewritten, lines are only taken out" || bad "unbind: only removes" "$(diff "$A" "${TMP}/unbound.yaml" | grep '^>' | head -2)"
python3 -I "$PY" unbind < "${TMP}/unbound.yaml" > "${TMP}/twice.out"; urc=$?
[ "$urc" = 1 ] && grep -q '^unreadable' "${TMP}/twice.out" && ok "unbind: text with no binding to take out is refused (exit 1), so a bound plant cannot pass as unbound" || bad "unbind: refuses a no-op" "rc=$urc"

# ------------------------------------------------------------------ 3. the path as a script
BIN="${TMP}/bin"; mkdir -p "$BIN"
cat > "$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
# The product, stood in for. The list is computed from what origin's main holds: listed when the blueprint is there
# with no binding present, declared when site/values/identity.yaml names the slug under everyone. SB_MODE breaks it.
echo "$*" >> "${SB}/calls.log"
bp="$(git --git-dir="${SB}/origin.git" show main:apps/argocd-sso-blueprint.yaml 2>/dev/null)"
vals="$(git --git-dir="${SB}/origin.git" show main:site/values/identity.yaml 2>/dev/null)"
bound=no; [ -n "$bp" ] && case "$(printf '%s' "$bp" | python3 -I "$SB_PY" bindings)" in "0 present"*) ;; *) bound=yes ;; esac
every=false; printf '%s\n' "$vals" | grep -A3 '^  access:' | grep '^ *- argocd' >/dev/null && every=true
case "${SB_MODE:-}" in
  never-lists) bp="" ;;
  ignores-everyone) every=false ;;
  ignores-binding) bound=no ;;
esac
case "$*" in
  *"get configmap tockmox-identity-open-applications -o json"*)
    rows=""
    [ -n "$bp" ] && [ "$bound" = no ] && rows="{\"slug\": \"argocd\", \"name\": \"Argo CD sign-in\", \"group\": \"\", \"everyone\": ${every}}"
    python3 -c 'import json,sys; print(json.dumps({"kind":"ConfigMap","data":{"report.json":json.dumps({"version":1,"generatedAt":"2026-11-13T10:00:00Z","applications":9,"open":json.loads("["+sys.argv[1]+"]"),"everyoneNotFound":[]})}}))' "$rows" ;;
  *"get cronjob tockmox-open-applications -o json"*)
    val='[]'; [ "$every" = true ] && val='[\"argocd\"]'
    [ "${SB_MODE:-}" = everyone-sticks ] && val='[\"argocd\"]'
    printf '{"kind":"CronJob","spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"name":"list","env":[{"name":"TOCKMOX_OPEN_TO_EVERYONE","value":"%s"}]}]}}}}}}\n' "$val" ;;
  *"annotate applications.argoproj.io"*) echo "application.argoproj.io/root annotated" ;;
  *) echo "stub kubectl: no answer for: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$BIN/kubectl"
GT="${TMP}/tree"; mkdir -p "$GT/paths"; ln -s "${HERE}/lib" "$GT/lib"
# sandbox ... a P09 state that ended PASS, a site repository as the external route's installer leaves its identity
# values (one key, apps), and a bare repository as its origin
sandbox() {
  local d; d="$(mktemp -d "${TMP}/sbx.XXXXXX")"
  mkdir -p "$d/p09" "$d/site/site/values" "$d/site/apps"
  git init -q --bare "$d/origin.git"
  printf 'apps: {}\n' > "$d/site/site/values/identity.yaml"
  ( cd "$d/site" && git init -q . && git checkout -q -b main 2>/dev/null; git add -A \
      && git -c user.name=t -c user.email=t@example.invalid commit -q -m site && git remote add origin "$d/origin.git" && git push -q origin main ) >/dev/null 2>&1
  : > "$d/p09/p09-passed"
  printf 'export SITE_REPO=%s\n' "$d/site" > "$d/p09/session.env"
  printf '%s' "$d"
}
# run_p14 FILE SANDBOX [VAR=VALUE ...] ... the path as run.sh runs it; prints "rc|receipt"
run_p14() {
  local f="$1" d="$2"; shift 2
  env SB="$d" SB_PY="$PY" PATH="${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="$d/r" TOCKMOX_PATH_NAME=P14-open-applications KUBE_CONTEXT=stub-ctx \
      TOCKMOX_DOCS_REF=HEAD TOCKMOX_P14_FROM_TREE=1 TOCKMOX_P14_ARGO_PAGE_FILE="${TREE}/docs/administration/argocd.md" \
      TOCKMOX_P14_ID_PAGE_FILE="${TREE}/docs/administration/identity.md" TOCKMOX_P14_WAIT=0 TOCKMOX_P14_POLL=0 \
      TOCKMOX_P09_STATE="$d/p09" "$@" bash "$f" > "$d/out" 2>&1
  local rc=$?
  printf '%s|%s' "$rc" "$(cut -d' ' -f1 "$d/r/P14-open-applications" 2>/dev/null)"
}
failed_rows() { awk -F'\t' '$3 != $4 {print $2}' "$1/p09/p14/verdicts.tsv" 2>/dev/null; }

d="$(sandbox)"; r="$(run_p14 "$P14" "$d")"
is "path: green end to end against an honest product: exit 0 and a PASS receipt" "0|PASS" "$r"
[ -z "$(failed_rows "$d")" ] && [ "$(grep -c 'row [123]:' "$d/p09/p14/verdicts.tsv" 2>/dev/null)" = 3 ] && ok "path: the three rows were each recorded, and no row is red" || bad "path: three rows" "$(failed_rows "$d" | head -3); $(tail -5 "$d/out" | tr '\n' ';' | cut -c1-300)"
[ "$(git --git-dir="$d/origin.git" show main:apps/argocd-sso-blueprint.yaml | sha256sum)" = "$(sha256sum < "$A")" ] && ok "path: origin ends with block A as the page prints it, byte for byte" || bad "path: origin holds block A" ""
[ "$(git --git-dir="$d/origin.git" rev-list --count main)" = 4 ] && ok "path: three commits reached origin, one per row" || bad "path: three commits" "$(git --git-dir="$d/origin.git" rev-list --count main)"
git --git-dir="$d/origin.git" show main~2:apps/argocd-sso-blueprint.yaml | grep policybinding >/dev/null && bad "path: the first commit plants no binding" "policybinding in the planted file" || ok "path: the first commit plants the application with no binding"
git --git-dir="$d/origin.git" show main~1:site/values/identity.yaml | grep '^ *- argocd' >/dev/null && ! git --git-dir="$d/origin.git" show main:site/values/identity.yaml | grep 'everyone' >/dev/null \
  && ok "path: the declaration names argocd in the second commit and is gone again in the third" || bad "path: the declaration comes and goes" ""
git --git-dir="$d/origin.git" show main:site/values/identity.yaml | grep '^      - argocd-sso-blueprint$' >/dev/null && ok "path: the blueprint list (block B) is in the delivered values, as printed" || bad "path: block B delivered" ""
[ -s "$d/calls.log" ] && ! grep -v -- '--context=stub-ctx' "$d/calls.log" >/dev/null && ok "path: every kubectl call names its cluster ($(grep -c . "$d/calls.log") calls)" || bad "path: every call names its cluster" "$(grep -v -- '--context=stub-ctx' "$d/calls.log" | head -2)"
grep -q 'DOES NOT PROVE' "$d/out" && grep -q 'SUCCESS CONDITIONS STATED' "$d/out" && ok "path: the log says what the run does not prove, and what success conditions the pages state" || bad "path: caveats in the log" ""

# one broken product per row: the path must fail, and at that row
broken() { # MODE LABEL ROW-TEXT
  local d r; d="$(sandbox)"; r="$(run_p14 "$P14" "$d" SB_MODE="$1")"
  if [ "$r" = "1|PRODUCT_FAIL" ] && failed_rows "$d" | grep -- "$3" >/dev/null; then ok "$2"
  else bad "$2" "rc|receipt=[${r}] red rows: $(failed_rows "$d" | cut -c1-80 | tr '\n' ';')"; fi
}
broken never-lists "red: a product that never lists the unbound application fails row 1" "row 1:"
broken ignores-everyone "red: a product that keeps warning about a declared application fails row 3" "row 3:"
broken ignores-binding "red: a product that still lists a bound application fails row 2" "row 2:"
broken everyone-sticks "red: a job that still reads the declaration when the list clears fails the row that says the binding cleared it" "TOCKMOX_OPEN_TO_EVERYONE"

# mutated copies of the path, each of which must not end PASS against the honest product
mutated() { # LABEL OLD NEW
  local d r f; f="$(mktemp "${GT}/paths/m.XXXXXX")"
  mut "$P14" "$f" "$2" "$3" 2>/dev/null || { bad "$1" "the edit changed nothing"; return; }
  d="$(sandbox)"; r="$(run_p14 "$f" "$d")"
  [ "$r" != "0|PASS" ] && ok "mutation: ${1}: not a PASS (${r})" || bad "mutation: ${1}" "the mutated copy still ended 0|PASS"
}
mutated "a path that plants block A unedited (bound) cannot show row 1" 'verdict unbind < "${STATE}/block-a.yaml" > "${STATE}/unbound.yaml"' 'cat "${STATE}/block-a.yaml" > "${STATE}/unbound.yaml"'
mutated "a path that never pushes cannot show any row" '&& git -C "$SITE_REPO" push origin main > "${STATE}/${s}.push" 2>&1' '&& true > "${STATE}/${s}.push" 2>&1'
mutated "a path that leaves the page's example slug in the declaration cannot show row 3" 'sed "s/^\\( *- \\)${PAGE_SLUG}' 'sed "s/^\\( *- \\)no-such-${PAGE_SLUG}'
mutated "a path that binds without taking the declaration out fails the row that says the binding cleared it" 'cat "${STATE}/values-before-everyone" > "${SITE_REPO}/${VALUES_PATH}"' ': "${STATE}/values-before-everyone"'
# a site values file that already has the key cannot take the block as printed: a red row, and nothing is pushed
d="$(sandbox)"; printf 'authentik:\n  x: 1\n' >> "$d/site/site/values/identity.yaml"; ( cd "$d/site" && git -c user.name=t -c user.email=t@example.invalid commit -q -am pre && git push -q origin main ) >/dev/null 2>&1
r="$(run_p14 "$P14" "$d")"
[ "$r" != "0|PASS" ] && [ "$(git --git-dir="$d/origin.git" rev-list --count main)" = 2 ] && ok "path: a values file that already has a top-level authentik key is a red row, and nothing is pushed" || bad "path: existing authentik key" "$r; commits $(git --git-dir="$d/origin.git" rev-list --count main)"

# ------------------------------------------------------------------ 4. the gate
cat > "${TMP}/gbin-kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "${TMP}/kcalls"
exit 1
STUB
mkdir -p "${TMP}/gbin"; mv "${TMP}/gbin-kubectl" "${TMP}/gbin/kubectl"; chmod +x "${TMP}/gbin/kubectl"
run_gate() { # FILE STATE-DIR ... prints "rc|receipt|kubectl calls"
  rm -rf "${TMP}/gr" "${TMP}/kcalls"
  env PATH="${TMP}/gbin:${PATH}" OUTCOME_RECEIPT_DIR="${TMP}/gr" TOCKMOX_PATH_NAME=P14-open-applications KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
      TOCKMOX_P14_BUDGET=0 ${2:+TOCKMOX_P09_STATE="$2"} bash "$1" > "${TMP}/gout" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "${TMP}/gr/P14-open-applications" 2>/dev/null)" "$(grep -c . "${TMP}/kcalls" 2>/dev/null || echo 0)"
}
gate() { is "gate: ${1}: BLOCKED, exit 0, and no cluster call" "0|BLOCKED|0" "$(run_gate "$P14" "${2:-}")"; }
gate "no P09 state directory named" ""
gd="${TMP}/gate-p09"; mkdir -p "$gd"
gate "a P09 state directory that never ended PASS (no p09-passed marker)" "$gd"
: > "$gd/p09-passed"
gate "a P09 that passed but recorded no site repository" "$gd"
mkdir -p "${TMP}/gsite"; ( cd "${TMP}/gsite" && git init -q . ) >/dev/null 2>&1
printf 'export SITE_REPO=%s\n' "${TMP}/gsite" > "$gd/session.env"
gate "a site repository with no remote named origin (the built-in forge route)" "$gd"
grep -q 'Run the external route' "${TMP}/gout" && ok "gate: the reason names the route to run instead" || bad "gate: reason" "$(tail -2 "${TMP}/gout")"
gm="$(mktemp "${GT}/paths/g.XXXXXX")"
mut "$P14" "$gm" '[ -f "${P09_STATE}/p09-passed" ] || blocked' '[ -d "${P09_STATE}" ] || blocked'
rm -f "$gd/p09-passed" "$gd/session.env"
run_gate "$gm" "$gd" >/dev/null
if grep -q 'no p09-passed marker' "${TMP}/gout"; then bad "mutation: a gate that does not read the p09-passed marker" "the mutated copy still blocked on the marker"
else ok "mutation: a gate that does not read the p09-passed marker goes past it (it stops later, for another reason), so the marker case above would catch it"; fi
grep -F '[ -f "${P09_STATE}/p09-passed" ]' "$P14" >/dev/null && grep -E '^P14 \| BLOCKED \| nofile:TOCKMOX_P09_STATE/p09-passed \|' "${HERE}/expected-outcomes.txt" >/dev/null \
  && ok "gate: expected-outcomes.txt allows P14 BLOCKED on the marker the path itself blocks on" || bad "gate: the expected-outcomes row" "no P14 row on nofile:TOCKMOX_P09_STATE/p09-passed"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

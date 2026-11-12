#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P12, the bring-your-own-CA path. No cluster. Four layers.
#
#   1. The verdicts (lib/p12-byo-ca.py): a green fixture per verdict, then one red fixture per way the page's
#      claim can be false.
#   2. The whole path run against a stub kubectl and a stub kubeseal that serve a coherent fake install (a CA the
#      path generated, a certificate signed by it, a chart CA beside it) and a real local git remote. Green first:
#      every row passes, every kubectl call names its context. Then one PLANTED FIXTURE per row, each of which
#      must turn that row red and the outcome PRODUCT_FAIL.
#      The sealing certificate is not a precondition: when it is absent the path runs the escrow page's key export
#      (a fake tockmox-install.sh stands in for the installer and writes it), and the fixtures plant what that step must
#      catch (an installer that writes nothing, one that changes a sealed file, a plain-YAML backup, a dry run that
#      writes), and the NOTE and no installer call when the file is already there.
#   3. The path's own gate: BLOCKED, exit 0, no cluster call, whenever P09's state, its PASS marker, the site
#      repository or its remote is missing (the sealing certificate is not on the list); the same checks against mutated copies of
#      P12 that must not be BLOCKED; and the full run.sh with no P09 state, which must be green and not UNCONVERTED.
#   4. Mutated copies of P12 that lose a guard (an expectation compared with itself, the refusal of an empty
#      context) and must stop catching what the fixtures plant.
#
# The page's blocks are pasted into bash here (TOCKMOX_WS_SHELL=bash, the fallback P09 also has): the stubs and
# the verdicts are what is under test, not zsh. The page is read from this working tree.
#
#   ./tests/executed-docs/byo-ca-test.sh
#   P12=/path/to/P12.sh ./tests/executed-docs/byo-ca-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
# shellcheck disable=SC2034  # variables read by the stubs through the environment
# shellcheck disable=SC1003  # the quote characters in the mutation edits are literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
P12="${P12:-${HERE}/paths/P12-bring-your-own-ca.sh}"
PY="${HERE}/lib/p12-byo-ca.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }
v() { python3 -I "$PY" "$@"; }
mut() { # IN OUT OLD NEW ... a copy with OLD replaced by NEW; refuses an edit that changes nothing
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
t = s.replace(old, new)
assert t != s, "the edit changed nothing: %r" % old
open(dst, "w", encoding="utf-8").write(t)
PY
}

# ============================================================ 1. the verdicts
FPL="sha256 Fingerprint=AB:CD:EF:01"
[ "$(printf '%s\n' "$FPL" | v fingerprint)" = "AB:CD:EF:01" ] && ok "fingerprint: read from OpenSSL 3 output" || bad "fingerprint: OpenSSL 3"
[ "$(printf 'SHA256 Fingerprint=ab:cd\n' | v fingerprint)" = "AB:CD" ] && ok "fingerprint: OpenSSL 1.1 spelling, case folded" || bad "fingerprint: OpenSSL 1.1"
[ "$(printf 'nothing here\n' | v fingerprint)" = none ] && ok "fingerprint: no fingerprint reads none, never empty" || bad "fingerprint: none"
[ "$(printf 'tockmox-platform\n' | v namespace)" = tockmox-platform ] && ok "namespace: one name is read" || bad "namespace: one"
[ "$(printf 'a\nb\n' | v namespace)" != a ] && ok "namespace: two lines are not one namespace" || bad "namespace: two lines"
[ "$(printf '' | v namespace)" = none ] && ok "namespace: an empty read is none" || bad "namespace: empty"
[ "$(printf 'error: something broke\n' | v namespace | cut -c1-8)" = "not exac" ] && ok "namespace: an error message is not a namespace" || bad "namespace: error message"
[ "$(printf 'notAfter=Nov 10 21:00:00 2036 GMT\n' | v enddate --now 1762800000)" = future ] && ok "enddate: 2036 is in the future" || bad "enddate: future"
[ "$(printf 'notAfter=Nov 10 21:00:00 2026 GMT\n' | v enddate --now 1900000000)" = past ] && ok "enddate: an end before now is past" || bad "enddate: past"
[ "$(printf '' | v enddate)" = none ] && ok "enddate: no end date reads none" || bad "enddate: none"

SEAL="${TMP}/sealed.yaml"
mkseal() { # NAME NS TYPE [DROP-KEY]
  { printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  creationTimestamp: null\n  name: %s\n  namespace: %s\nspec:\n  encryptedData:\n' "$1" "$2"
    [ "${4:-}" = tls.crt ] || printf '    tls.crt: AgBxxxx\n'
    [ "${4:-}" = tls.key ] || printf '    tls.key: AgByyyy\n'
    printf '  template:\n    metadata:\n      creationTimestamp: null\n      name: %s\n      namespace: %s\n    type: %s\n' "$1" "$2" "$3"; } > "$SEAL"
}
GOODSEAL="sealed tls Secret site-ca-root in tockmox-platform"
mkseal site-ca-root tockmox-platform kubernetes.io/tls
[ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" = "$GOODSEAL" ] && ok "sealed: a SealedSecret of the right name, namespace, type and keys" || bad "sealed: green"
mkseal other tockmox-platform kubernetes.io/tls;      [ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" != "$GOODSEAL" ] && ok "sealed: a wrong name is red" || bad "sealed: name"
mkseal site-ca-root default kubernetes.io/tls;        [ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" != "$GOODSEAL" ] && ok "sealed: a wrong namespace is red" || bad "sealed: namespace"
mkseal site-ca-root tockmox-platform Opaque;          [ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" != "$GOODSEAL" ] && ok "sealed: a wrong template type is red" || bad "sealed: type"
mkseal site-ca-root tockmox-platform kubernetes.io/tls tls.key; [ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" != "$GOODSEAL" ] && ok "sealed: a missing tls.key is red" || bad "sealed: key"
: > "$SEAL";                                          [ "$(v sealed --name site-ca-root --ns tockmox-platform < "$SEAL")" != "$GOODSEAL" ] && ok "sealed: a zero-byte file (a failed seal) is red" || bad "sealed: empty"
CT=$'NS NAME READY ISSUER\na web True site-ca\nb api True site-ca\n'
[ "$(printf '%s' "$CT" | v certs --issuer site-ca)" = "all 2 True on site-ca" ] && ok "certs: every row True on the issuer" || bad "certs: green"
[ "$(printf '%s' "${CT/api True site-ca/api True tockmox-ca}" | v certs --issuer site-ca | cut -c1-8)" = "1 of 2 n" ] && ok "certs: a row still on the old issuer is red" || bad "certs: old issuer"
[ "$(printf '%s' "${CT/api True/api False}" | v certs --issuer site-ca | cut -c1-8)" = "1 of 2 n" ] && ok "certs: a row not True is red" || bad "certs: not ready"
[ "$(printf 'NS NAME READY ISSUER\n' | v certs --issuer site-ca)" = "no Certificate rows" ] && ok "certs: a table with no rows is red, not vacuously green" || bad "certs: empty"
# the rows the page says keep an issuer of their own (seen on a cluster: the backup plugin's two)
OWN=barman-cloud-client,barman-cloud-server
CTB="${CT}"$'p barman-cloud-client True plat-selfsigned-issuer\np barman-cloud-server True plat-selfsigned-issuer\n'
[ "$(printf '%s' "$CTB" | v certs --issuer site-ca --own "$OWN")" = "all 4 True on site-ca (2 on their own issuer: barman-cloud-client, barman-cloud-server)" ] && ok "certs: the two rows the page names may keep their own issuer, and are named in the verdict" || bad "certs: own issuer" "$(printf '%s' "$CTB" | v certs --issuer site-ca --own "$OWN")"
[ "$(printf '%s' "$CTB" | v certs --issuer site-ca | cut -c1-8)" = "2 of 4 n" ] && ok "certs: without the page's exception those two rows are red" || bad "certs: no exception"
[ "$(printf '%s' "${CTB/barman-cloud-server True/barman-cloud-server False}" | v certs --issuer site-ca --own "$OWN" | cut -c1-8)" = "1 of 4 n" ] && ok "certs: an excepted row that is not True is still red" || bad "certs: excepted not ready"
[ "$(printf '%s' "${CTB/b api True site-ca/b api True some-other-issuer}" | v certs --issuer site-ca --own "$OWN" | cut -c1-8)" = "1 of 4 n" ] && ok "certs: a row on another issuer that the page does not name is red" || bad "certs: unnamed other issuer"
[ "$(printf 'NS NAME READY ISSUER\np barman-cloud-client True plat-selfsigned-issuer\n' | v certs --issuer site-ca --own "$OWN")" = "no row names site-ca" ] && ok "certs: a table of excepted rows only is red (nothing moved to the issuer)" || bad "certs: only excepted rows"
IT=$'NAME CA\nsite-ca site-ca-root\n'
[ "$(printf '%s' "$IT" | v issuers --issuer site-ca --secret site-ca-root)" = "one CA issuer: site-ca with site-ca-root" ] && ok "issuers: one CA issuer, the right one" || bad "issuers: green"
[ "$(printf '%s%s' "$IT" $'tockmox-ca tockmox-ca-root\n' | v issuers --issuer site-ca --secret site-ca-root | cut -c1-6)" = "2 CA i" ] && ok "issuers: a second CA issuer (the chart's still minting) is red" || bad "issuers: two"
[ "$(printf '%s%s' "$IT" $'tockmox-ca-bootstrap <none>\n' | v issuers --issuer site-ca --secret site-ca-root | cut -c1-3)" = "one" ] && ok "issuers: a self-signed issuer with no CA secret is not a CA issuer" || bad "issuers: bootstrap"
[ "$(printf 'NAME CA\ntockmox-ca tockmox-ca-root\n' | v issuers --issuer site-ca --secret site-ca-root)" = "the one CA issuer is tockmox-ca/tockmox-ca-root" ] && ok "issuers: only the chart's CA is red" || bad "issuers: chart only"
[ "$(printf '' | v issuers --issuer site-ca --secret site-ca-root)" = "no ClusterIssuer rows" ] && ok "issuers: an empty read is red" || bad "issuers: empty"
[ "$(printf 'a\n b \na\n' | v count --line a)" = 2 ] && ok "count: whole lines, whitespace trimmed" || bad "count"

# ============================================================ 2. the whole path, against stubs
FX="${TMP}/fx"; mkdir -p "$FX/bin"
mkca() { # NAME CN
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 -subj "/CN=$2" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$FX/$1.key" -out "$FX/$1.crt" >/dev/null 2>&1
}
mkca chart "Chart CA fixture"; mkca other "Other CA fixture"
cat > "$FX/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# a stub cluster: serves a coherent fake install from files; a knob file in $FX turns one thing wrong
echo "$*" >> "$FX/kcalls"
a="$*"
knob() { [ -e "$FX/knob-$1" ]; }
b64() { base64 | tr -d '\n'; }
case "$a" in
  *"get pods -A"*) if knob wrong-ns; then echo kube-system; else echo "$NS"; fi ;;
  *"get secret -A --field-selector"*) printf '%s' "$NS" ;;
  *"get secret tockmox-ca-root -o jsonpath"*)
    n=$(cat "$FX/adopt-reads" 2>/dev/null || echo 0); echo $((n+1)) > "$FX/adopt-reads"
    if knob adopt-fp-other && [ "$n" -ge 1 ]; then b64 < "$FX/other.crt"; else b64 < "$FX/chart.crt"; fi ;;
  *"get secret tockmox-ca-root -o json"*)
    python3 -c 'import json,sys,base64,os; f=os.environ["FX"]; e=lambda p: base64.b64encode(open(p,"rb").read()).decode(); print(json.dumps({"data":{"tls.crt":e(f+"/chart.crt"),"tls.key":e(f+"/chart.key")}}))' ;;
  *"get secret site-ca-root"*"tls"*"crt"*) if knob unsealed-other; then b64 < "$FX/other.crt"; else b64 < "$ST/ca/ca.crt"; fi ;;
  *"get secret site-ca-root"*"tls"*"key"*) if knob key-other; then b64 < "$FX/other.key"; else b64 < "$ST/ca/ca.key"; fi ;;
  *"get clusterissuer site-ca"*) if knob not-ready; then echo False; else echo True; fi ;;
  *"get certificate -A"*)
    n=$(cat "$FX/cert-reads" 2>/dev/null || echo 0); echo $((n+1)) > "$FX/cert-reads"
    if knob certs-late && [ "$n" -lt 2 ]; then printf 'NS NAME READY ISSUER\nns1 web-tls True site-ca\nns2 api-tls True tockmox-ca\n'; else cat "$FX/certs.txt"; fi ;;
  *"get clusterissuer -o custom-columns"*) cat "$FX/issuers.txt" ;;
  *"get ingress"*) printf 'ns1\tweb-tls\n' ;;
  *"get secret web-tls"*"ca"*"crt"*)
    if knob cacrt-other; then b64 < "$FX/other.crt"; else b64 < "$ST/ca/ca.crt"; fi ;;
  *"get secret web-tls"*"tls"*"crt"*) b64 < "$FX/leaf.crt" ;;
  *"annotate"*) if knob stray; then echo x > "$SITE_REPO/stray.txt"; fi; echo annotated ;;
  *"get applications"*) : ;;
  *"config view"*) printf 'https://api.fixture.invalid:6443' ;;
  *"get deploy -A"*) printf 'kube-system/sealed-secrets' ;;
  *"create secret tls"*) printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: site-ca-root\n  namespace: %s\ntype: kubernetes.io/tls\n' "$NS" ;;
  *) echo "stub kubectl: unhandled: $a" >&2; exit 1 ;;
esac
STUB
cat > "$FX/bin/kubeseal" <<'STUB'
#!/usr/bin/env bash
# a stub kubeseal: reads the Secret on stdin, writes a SealedSecret naming what it read
echo "kubeseal $*" >> "$FX/kcalls"
in="$(cat)"
if [ -e "$FX/knob-seal-empty" ]; then exit 0; fi
ns="$(printf '%s' "$in" | python3 -c 'import sys,json,re; t=sys.stdin.read()
try: print(json.loads(t)["metadata"]["namespace"])
except Exception: print(re.search(r"(?m)^  namespace: (\S+)", t).group(1))')"
[ -e "$FX/knob-seal-wrong-ns" ] && ns=default
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  creationTimestamp: null\n  name: site-ca-root\n  namespace: %s\nspec:\n  encryptedData:\n    tls.crt: AgBxxxx\n    tls.key: AgByyyy\n  template:\n    metadata:\n      creationTimestamp: null\n      name: site-ca-root\n      namespace: %s\n    type: kubernetes.io/tls\n' "$ns" "$ns"
STUB
chmod +x "$FX/bin/kubectl" "$FX/bin/kubeseal"
# a stub age-keygen (the real one is not needed to test the path): -o FILE writes an identity, -y FILE prints its public key
cat > "$FX/bin/age-keygen" <<'STUB'
#!/usr/bin/env bash
case "$1" in -o) printf 'AGE-SECRET-KEY-FIXTURE\n' > "$2" ;; -y) echo age1fixturepublickey ;; esac
STUB
# a fake installer: logs every call; `bootstrap-secrets --mode reuse` writes the public certificate into the site and an
# encrypted backup to --backup-out, as the real one does; a knob file in $FX turns one thing wrong
mkdir -p "$FX/tockmox/install"
cat > "$FX/tockmox/install/tockmox-install.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/icalls"
site=""; out=""; dry=0
while [ $# -gt 0 ]; do case "$1" in --site) site="$2"; shift 2 ;; --backup-out) out="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) shift ;; esac; done
if [ "$dry" = 1 ]; then
  echo "Plan (dry run, nothing changed)"
  [ -e "$FX/knob-dry-writes" ] && cp "$FX/chart.crt" "$site/secrets/sealed-secrets-cert.pem"
  exit 0
fi
[ -e "$FX/knob-inst-nothing" ] && exit 0
cp "$FX/chart.crt" "$site/secrets/sealed-secrets-cert.pem"
if [ -e "$FX/knob-backup-yaml" ]; then printf '# tockmox-sealed-secrets-key-backup v1\nkind: Secret\n  tls.key: AAAA\n' > "$out"
else printf 'age-encryption.org/v1\n-> X25519 fixture\nencrypted-bytes\n' > "$out"; fi
[ -e "$FX/knob-inst-mutates" ] && printf 'changed\n' >> "$site/secrets/db.sealed.yaml"
[ -e "$FX/knob-quiet" ] || echo "encrypted key backup written: $out"
STUB
chmod +x "$FX/bin/age-keygen" "$FX/tockmox/install/tockmox-install.sh"
GOODCERTS=$'NS NAME READY ISSUER\nns1 web-tls True site-ca\nns2 api-tls True site-ca\ntockmox-platform barman-cloud-client True plat-plugin-barman-cloud-selfsigned-issuer\ntockmox-platform barman-cloud-server True plat-plugin-barman-cloud-selfsigned-issuer\n'
GOODISS=$'NAME CA\nsite-ca site-ca-root\n'

# setup_run DIR ... a P09 state directory, a site repository with a real local remote, and the fixtures for one run
setup_run() {
  local d="$1"
  rm -rf "$d" "$FX"/knob-* "$FX/adopt-reads" "$FX/kcalls" "$FX/icalls" "$FX"/leaf.*
  mkdir -p "$d/p09" "$d/site/secrets" "$d/site/site/values" "$d/site/apps"
  git init -q --bare -b main "$d/origin.git"
  ( cd "$d/site" || exit 1
    git init -q -b main
    printf 'cert\n' > secrets/sealed-secrets-cert.pem
    printf 'kind: SealedSecret\nname: db\n' > secrets/db.sealed.yaml
    printf '# Generated\nglobal:\n  internalDomain: fixture.invalid\n  certIssuer: tockmox-ca\n  timezone: UTC\n' > site/values/global.yaml
    printf '# Overrides for tockmox-platform.\naddressPool:\n  range: 192.0.2.10-192.0.2.20\napps: {}\n' > site/values/platform.yaml
    git add -A
    git -c user.name=t -c user.email=t@example.invalid commit -q -m site
    git remote add origin "$d/origin.git"
    git push -q origin main ) >/dev/null 2>&1
  : > "$d/p09/p09-passed"
  printf 'export SITE_REPO=%s\nexport TOCKMOX=%s\n' "$d/site" "$FX/tockmox" > "$d/p09/session.env"
  printf '%s' "$GOODCERTS" > "$FX/certs.txt"; printf '%s' "$GOODISS" > "$FX/issuers.txt"
}
# run_p12 FILE DIR [VAR=VALUE ...] ... the path as run.sh runs it; output in $TMP/out, prints "rc|receipt"
run_p12() {
  local f="$1" d="$2"; shift 2
  rm -rf "$TMP/r"
  env PATH="$FX/bin:$PATH" FX="$FX" ST="$d/p09/p12" NS=tockmox-platform OUTCOME_RECEIPT_DIR="$TMP/r" TOCKMOX_PATH_NAME=P12-bring-your-own-ca \
      KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD TOCKMOX_P12_FROM_TREE=1 TOCKMOX_WS_SHELL=bash TOCKMOX_P12_PAGE_FILE="${REPO}/docs/administration/bring-your-own-ca.md" \
      TOCKMOX_P12_ESCROW_PAGE_FILE="${REPO}/docs/operations/sealed-secrets-key-escrow.md" \
      TOCKMOX_P09_STATE="$d/p09" TOCKMOX_P12_BUDGET=600 TOCKMOX_P12_SEALED_WAIT=0 TOCKMOX_P12_REISSUE_WAIT=0 "$@" \
      bash "$f" > "$TMP/out" 2>&1
  local rc=$?
  printf '%s|%s' "$rc" "$(cut -d' ' -f1 "$TMP/r/P12-bring-your-own-ca" 2>/dev/null)"
}
# the leaf is made between S05 and S07 by wrapping kubectl: sign lazily, on the first request for it
mv "$FX/bin/kubectl" "$FX/bin/kubectl.real"
cat > "$FX/bin/kubectl" <<'WRAP'
#!/usr/bin/env bash
case "$*" in
  *"get secret web-tls"*"tls"*"crt"*)
    if [ ! -s "$FX/leaf.crt" ]; then
      if [ -e "$FX/knob-leaf-chart" ]; then sc="$FX/chart.crt"; sk="$FX/chart.key"; else sc="$ST/ca/ca.crt"; sk="$ST/ca/ca.key"; fi
      openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj "/CN=console.fixture.invalid" -keyout "$FX/leaf.key" -out "$FX/leaf.csr" >/dev/null 2>&1
      openssl x509 -req -in "$FX/leaf.csr" -CA "$sc" -CAkey "$sk" -CAcreateserial -days 5 -out "$FX/leaf.crt" >/dev/null 2>&1
    fi ;;
esac
exec "$(dirname "$0")/kubectl.real" "$@"
WRAP
chmod +x "$FX/bin/kubectl"

RUN="${TMP}/run"
setup_run "$RUN"
r="$(run_p12 "$P12" "$RUN")"
if [ "$r" = "0|PASS" ] && ! grep -q '^RECORDED FAIL' "$TMP/out"; then ok "green: the whole path passes against a coherent fake install ($(grep -E '^ASSERTIONS:' "$TMP/out" | tail -1))"
else bad "green: the whole path passes" "[${r}] $(grep -E '^RECORDED FAIL|^BLOCKED|^INFRA|^FAIL' "$TMP/out" | head -5 | tr '\n' ';' | cut -c1-500)"; fi
n_rows="$(grep -c '^RECORDED PASS' "$TMP/out")"
[ "$n_rows" -ge 30 ] && ok "green: ${n_rows} rows recorded, none of them red" || bad "green: row count" "${n_rows}"
grep -q '^RECORDED (xfail): the global.yaml snippet appended as printed' "$TMP/out" && ok "green: the page's global.yaml snippet is pinned as a known defect (xfail)" || bad "green: xfail row for the global snippet"
# every cluster call names its context, and every block was extracted: the verbatim sha is in the log
if ! grep -v '^kubeseal ' "$FX/kcalls" | grep -v -e '--context' >/dev/null; then ok "green: every kubectl call the path and the page made carried --context ($(grep -vc '^kubeseal ' "$FX/kcalls") calls)"
else bad "green: a kubectl call without --context" "$(grep -v '^kubeseal ' "$FX/kcalls" | grep -v -e '--context' | head -2)"; fi
[ "$(grep -c '^SHA256:' "$TMP/out")" -ge 13 ] && ok "green: every block's SHA256 is in the log (10 bash blocks and 3 YAML blocks, extracted not retyped)" || bad "green: provenance" "$(grep -c '^SHA256:' "$TMP/out")"
git -C "$RUN/site" show --name-only --format= HEAD | grep 'apps/site-ca-issuer.yaml' >/dev/null && ok "green: the issuer file the page prints was committed and pushed" || bad "green: issuer committed"
grep -q '^  certIssuer: site-ca$' "$RUN/site/site/values/global.yaml" && grep -q '^  internalDomain: fixture.invalid$' "$RUN/site/site/values/global.yaml" && ok "green: global.yaml was merged, not replaced" || bad "green: merge"
# a second call after the work is done adds nothing: resumable
r2="$(run_p12 "$P12" "$RUN")"; [ "${r2%%|*}" = 0 ] && ok "resume: calling the path again after it finished replays the same verdicts" || bad "resume" "[${r2}]"

# planted fixtures: KNOB DESCRIPTION-FRAGMENT-OF-THE-ROW-THAT-MUST-BE-RED [EXTRA ENV]
plant() { # LABEL ROW-FRAGMENT SETUP-COMMAND
  local label="$1" frag="$2" setup="$3"
  setup_run "$RUN"; eval "$setup"
  r="$(run_p12 "$P12" "$RUN")"
  if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: " "$TMP/out" | grep -F -- "$frag" >/dev/null; then ok "planted: ${label} turns the row '${frag}' red and the outcome PRODUCT_FAIL"
  else bad "planted: ${label}" "[${r}] red rows: $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | tr '\n' ';' | cut -c1-400)"; fi
}
plant "a namespace that does not hold the chart's Secret" "step 1: the command prints one namespace" ': > "$FX/knob-wrong-ns"'
plant "a sealed file for the wrong namespace" "step 3: the file is one SealedSecret" ': > "$FX/knob-seal-wrong-ns"'
plant "a zero-byte sealed file (the redirect made it, kubeseal failed)" "step 3: the last line prints 1" ': > "$FX/knob-seal-empty"'
plant "an adoption fingerprint that differs from the one recorded" "step 4 adopt: the fingerprint read equals" ': > "$FX/knob-adopt-fp-other"'
plant "an unsealed Secret carrying another CA's certificate" "the unsealed site-ca-root carries the generated CA's certificate" ': > "$FX/knob-unsealed-other"'
plant "an unsealed Secret carrying another key" "the unsealed site-ca-root carries the generated CA's key" ': > "$FX/knob-key-other"'
plant "an issuer that is not Ready" "step 5: the first command prints True" ': > "$FX/knob-not-ready"'
plant "a Certificate still on the old issuer" "step 5: every Certificate row reads True" 'printf "NS NAME READY ISSUER\nns1 web-tls True site-ca\nns2 api-tls True tockmox-ca\n" > "$FX/certs.txt"'
plant "a Certificate that is not True" "step 5: every Certificate row reads True" 'printf "NS NAME READY ISSUER\nns1 web-tls False site-ca\n" > "$FX/certs.txt"'
plant "an issued certificate whose ca.crt is another CA's" "the ca.crt fingerprint read from the issued certificate" ': > "$FX/knob-cacrt-other"'
plant "an issued certificate signed by another CA" "issued.crt verifies against the generated CA" ': > "$FX/knob-leaf-chart"'
plant "an issued certificate signed by another CA (the page's own output)" "openssl verify prints 'issued.crt: OK'" ': > "$FX/knob-leaf-chart"'
plant "a second CA issuer still present" "exactly one ClusterIssuer has a CA secret" 'printf "NAME CA\nsite-ca site-ca-root\ntockmox-ca tockmox-ca-root\n" > "$FX/issuers.txt"'
plant "a stray file left in the site repository clone" "the site repository clone holds nothing but the page's commit" ': > "$FX/knob-stray"'
plant "a site repository whose remote refuses the push" "origin's main equals the local HEAD" 'git -C "$RUN/site" remote set-url origin "$RUN/does-not-exist.git"'
plant "a global.yaml with no certIssuer line to merge into" "global.yaml: certIssuer reads site-ca once" 'sed -i "/certIssuer/d" "$RUN/site/site/values/global.yaml"; git -C "$RUN/site" commit -qam x; git -C "$RUN/site" push -q origin main'

# the end-date case needs a CA that is already expired: the path generates its own, so plant one in its state first
setup_run "$RUN"; mkdir -p "$RUN/p09/p12/ca"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj "/CN=expired" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout "$RUN/p09/p12/ca/ca.key" -out "$RUN/p09/p12/ca/ca.crt" >/dev/null 2>&1
# the path keeps a CA it finds; back-date it by making the verdict see a past date through a wrapper on openssl x509 -enddate
mkdir -p "$TMP/bin-old"; cat > "$TMP/bin-old/openssl" <<'OLD'
#!/usr/bin/env bash
real=/usr/bin/openssl; [ -x "$real" ] || real="$(PATH="${PATH#*:}" command -v openssl)"
case "$*" in *"-enddate"*) echo "notAfter=Jan  1 00:00:00 2020 GMT"; "$real" "$@" | grep -v notAfter; exit 0 ;; esac
exec "$real" "$@"
OLD
chmod +x "$TMP/bin-old/openssl"
r="$(run_p12 "$P12" "$RUN" PATH="$TMP/bin-old:$FX/bin:$PATH")"
if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: step 2: the end date prints and is in the future" "$TMP/out" >/dev/null; then ok "planted: a CA whose end date is past turns the step 2 end-date row red"
else bad "planted: a past end date" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | head -3 | tr '\n' ';')"; fi

# ---- 2b. the sealing certificate is a prerequisite the path MEETS (S00), the documented way, not a precondition
# no_cert_run [KNOB...] ... a site that lacks the certificate (as on the external route), run, outputs in $TMP/out
no_cert_run() { # P12-FILE [KNOB ...]
  local f="$1"; shift
  setup_run "$RUN"
  git -C "$RUN/site" rm -q secrets/sealed-secrets-cert.pem && git -C "$RUN/site" -c user.name=t -c user.email=t@example.invalid commit -q -m "no cert" && git -C "$RUN/site" push -q origin main
  for k in "$@"; do : > "$FX/knob-$k"; done
  r="$(run_p12 "$f" "$RUN")"
}
S00P='RECORDED PASS: the key export saved secrets/sealed-secrets-cert.pem'
no_cert_run "$P12"
if [ "$r" = "0|PASS" ] && ! grep -q '^BLOCKED' "$TMP/out" && ! grep -q '^RECORDED FAIL' "$TMP/out"; then ok "escrow: a site WITHOUT the certificate is not BLOCKED: the key export writes it and the path goes on to PASS"
else bad "escrow: no certificate, installer writes it" "[${r}] $(grep -E '^RECORDED FAIL|^BLOCKED' "$TMP/out" | head -4 | tr '\n' ';' | cut -c1-400)"; fi
grep -F "$S00P" "$TMP/out" >/dev/null && grep -F 'RECORDED PASS: the encrypted key backup exists and is not plain YAML' "$TMP/out" >/dev/null \
  && grep -F 'RECORDED PASS: every *.sealed.yaml in secrets/ is byte-identical' "$TMP/out" >/dev/null \
  && grep -F 'RECORDED PASS: the dry run changes nothing' "$TMP/out" >/dev/null \
  && ok "escrow: the four S00 rows are recorded and green (certificate is PEM, backup is not YAML, sealed files unchanged, dry run changed nothing)" || bad "escrow: S00 rows" "$(grep -c 'S00-escrow' "$TMP/out") S00 lines"
[ "$(wc -l < "$FX/icalls")" = 2 ] && [ "$(head -1 "$FX/icalls" | grep -c -e '--dry-run')" = 1 ] && [ "$(tail -1 "$FX/icalls" | grep -c -e '--dry-run')" = 0 ] \
  && grep -F 'bootstrap-secrets --mode reuse --site' "$FX/icalls" >/dev/null && ok "escrow: the installer is called twice with the page's arguments, the dry run first, then without --dry-run" || bad "escrow: installer calls" "$(cat "$FX/icalls" 2>/dev/null | tr '\n' ';')"
git -C "$RUN/site" show --name-only --format= HEAD | grep -x 'secrets/sealed-secrets-cert.pem' >/dev/null && [ "$(git -C "$RUN/site" show --name-only --format= HEAD | grep -c .)" = 5 ] \
  && ok "escrow: the certificate the key export wrote is committed with the page's four files (five in the commit)" || bad "escrow: certificate committed" "$(git -C "$RUN/site" show --name-only --format= HEAD | tr '\n' ' ')"
grep -F 'SOURCE:   docs/operations/sealed-secrets-key-escrow.md' "$TMP/out" >/dev/null && [ "$(grep -c '^SHA256:' "$TMP/out")" -ge 14 ] && ok "escrow: the key export block's provenance names the escrow page and its SHA256 is logged beside the page's 13 (extracted, not retyped)" || bad "escrow: provenance" "$(grep -c '^SHA256:' "$TMP/out") sha lines; $(grep '^SOURCE' "$TMP/out" | sort -u | head -3 | tr '\n' ';')"
r2="$(run_p12 "$P12" "$RUN")"; [ "${r2%%|*}" = 0 ] && [ "$(wc -l < "$FX/icalls")" = 2 ] && ok "escrow: calling the path again does not run the installer again" || bad "escrow: resume" "[${r2}] $(wc -l < "$FX/icalls") calls"

no_cert_run "$P12" inst-nothing
if [ "${r#*|}" = PRODUCT_FAIL ] && ! grep -q '^BLOCKED' "$TMP/out" && grep -F "RECORDED FAIL: the key export saved secrets/sealed-secrets-cert.pem" "$TMP/out" >/dev/null; then ok "escrow: an installer that writes nothing is a FAIL row (not BLOCKED), and the outcome is PRODUCT_FAIL"
else bad "escrow: installer writes nothing" "[${r}] $(grep -E '^RECORDED FAIL|^BLOCKED' "$TMP/out" | head -4 | tr '\n' ';' | cut -c1-300)"; fi
no_cert_run "$P12" inst-mutates
if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: every *.sealed.yaml in secrets/ is byte-identical" "$TMP/out" >/dev/null; then ok "escrow: an installer that changes a sealed file turns the byte-identical row red"
else bad "escrow: sealed file changed" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | head -3 | tr '\n' ';')"; fi
no_cert_run "$P12" backup-yaml
if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: the encrypted key backup exists and is not plain YAML" "$TMP/out" >/dev/null; then ok "escrow: a backup written as plain YAML turns the encrypted-backup row red"
else bad "escrow: plain YAML backup" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | head -3 | tr '\n' ';')"; fi
no_cert_run "$P12" quiet
if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: page success condition: the key export's run ends with 'encrypted key backup written:'" "$TMP/out" >/dev/null; then ok "escrow: a key export that never prints the page's success line turns the success-condition row red"
else bad "escrow: success line missing" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | head -3 | tr '\n' ';')"; fi
no_cert_run "$P12" dry-writes
if [ "${r#*|}" = PRODUCT_FAIL ] && grep -F "RECORDED FAIL: the dry run changes nothing" "$TMP/out" >/dev/null; then ok "escrow: a dry run that writes the certificate turns the dry-run row red"
else bad "escrow: dry run writes" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-110 | head -3 | tr '\n' ';')"; fi
setup_run "$RUN"; r="$(run_p12 "$P12" "$RUN")"
if [ "$r" = "0|PASS" ] && grep -F 'NOTE:     S00: secrets/sealed-secrets-cert.pem is already in the site repository' "$TMP/out" >/dev/null && [ ! -e "$FX/icalls" ] \
   && [ "$(grep -c 'NOTE:     S00' "$TMP/out")" = 1 ]; then ok "escrow: a site that already holds the certificate logs one NOTE line and the installer is never called"
else bad "escrow: certificate present" "[${r}] installer calls: $(cat "$FX/icalls" 2>/dev/null | wc -l); $(grep 'S00' "$TMP/out" | head -3 | tr '\n' ';')"; fi
setup_run "$RUN"; git -C "$RUN/site" rm -q secrets/sealed-secrets-cert.pem && git -C "$RUN/site" -c user.name=t -c user.email=t@example.invalid commit -q -m "no cert" && git -C "$RUN/site" push -q origin main
printf 'export SITE_REPO=%s\n' "$RUN/site" > "$RUN/p09/session.env"
r="$(run_p12 "$P12" "$RUN")"
if [ "$r" = "0|BLOCKED" ] && grep -F 'installer that writes it is not at' "$TMP/out" >/dev/null; then ok "escrow: no certificate and no TOCKMOX in P09's session is BLOCKED naming the installer (an environment gap, not a failure)"
else bad "escrow: TOCKMOX missing" "[${r}] $(grep -E '^BLOCKED' "$TMP/out" | head -2 | tr '\n' ';')"; fi

# ============================================================ 3. the gate, and run.sh with no install
GT="${TMP}/gate"; mkdir -p "$GT/tree/paths" "$GT/bin"
ln -s "${HERE}/lib" "$GT/tree/lib"
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
exit 1
STUB
printf '#!/bin/sh\nexit 0\n' > "$GT/bin/kubeseal"
chmod +x "$GT/bin/kubectl" "$GT/bin/kubeseal"
gate_run() { # FILE STATE-DIR-OR-EMPTY [VAR=VALUE ...] ... prints "rc|receipt|kubectl calls"
  local f="$1" sd="$2"; shift 2
  rm -rf "$GT/r" "$GT/kcalls"
  env PATH="$GT/bin:$PATH" OUTCOME_RECEIPT_DIR="$GT/r" TOCKMOX_PATH_NAME=P12-bring-your-own-ca KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
      TOCKMOX_P12_BUDGET=0 TOCKMOX_WS_SHELL=bash TOCKMOX_P12_PAGE_FILE="${REPO}/docs/administration/bring-your-own-ca.md" TOCKMOX_P12_ESCROW_PAGE_FILE="${REPO}/docs/operations/sealed-secrets-key-escrow.md" TOCKMOX_P12_FROM_TREE=1 ${sd:+TOCKMOX_P09_STATE="$sd"} "$@" \
      bash "$f" > "$GT/out" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "$GT/r/P12-bring-your-own-ca" 2>/dev/null)" "$(grep -c . "$GT/kcalls" 2>/dev/null || echo 0)"
}
gate_state() { # DIR LEVEL ... build a P09 state at LEVEL: 0 none, 1 dir, 2 +marker, 3 +session, 4 +site dir, 5 +cert, 6 +origin
  local d="$1" l="$2"
  rm -rf "$d"
  [ "$l" -ge 1 ] && mkdir -p "$d/st"
  [ "$l" -ge 2 ] && : > "$d/st/p09-passed"
  [ "$l" -ge 4 ] && mkdir -p "$d/site/secrets"
  [ "$l" -ge 3 ] && printf 'export SITE_REPO=%s\n' "$d/site" > "$d/st/session.env"
  [ "$l" -ge 5 ] && printf 'cert\n' > "$d/site/secrets/sealed-secrets-cert.pem"
  if [ "$l" -ge 6 ]; then git init -q -b main "$d/site" >/dev/null 2>&1; git -C "$d/site" remote add origin "$d/o.git"; fi
  return 0
}
gate_full() { gate_state "$1" 6; : > "$1/site/secrets/sealed-secrets-cert.pem"; }
gate_cases() { # FILE PREFIX WANT(blocked|not)
  local f="$1" pre="$2" want="$3" d="$GT/g" got lab lvl
  for spec in "0|no P09 state directory named" "1|a P09 state directory with no PASS marker" "2|a PASS marker but no SITE_REPO in P09's session" \
              "3|a SITE_REPO that is not a directory" "4|a site repository with no sealing certificate and no remote (the remote is the precondition; the certificate is not)" "5|a site repository with no remote named origin"; do
    lvl="${spec%%|*}"; lab="${spec#*|}"
    gate_state "$d" "$lvl"
    if [ "$lvl" = 0 ]; then got="$(gate_run "$f" "")"; else got="$(gate_run "$f" "$d/st")"; fi
    if [ "$want" = blocked ]; then
      [ "$got" = "0|BLOCKED|0" ] && ok "${pre}${lab}: BLOCKED, exit 0, and no cluster call" || bad "${pre}${lab}" "rc|receipt|calls = [${got}]; $(tail -3 "$GT/out" | tr '\n' ';' | cut -c1-200)"
    else
      [ "$got" != "0|BLOCKED|0" ] && ok "${pre}${lab}: the mutated copy is NOT blocked, so the case above catches it" || bad "${pre}${lab}" "the mutated copy still declared BLOCKED"
    fi
  done
}
gate_cases "$P12" "gate: " blocked
# a complete state is not blocked: it goes on (here to its first kubectl call, which the stub refuses; the point is it was not BLOCKED)
gate_state "$GT/g" 6; : > "$GT/g/site/secrets/sealed-secrets-cert.pem"
got="$(gate_run "$P12" "$GT/g/st")"
[ "${got%%|*}" != 0 ] || [ "$(printf '%s' "$got" | cut -d'|' -f2)" != BLOCKED ] && ok "gate: a complete state is not blocked (it starts the steps: [${got}])" || bad "gate: complete state" "[${got}]"

# mutated copies: each removes one precondition and must stop being BLOCKED in the case aimed at it
mkp() { mut "$P12" "$GT/tree/paths/$1" "$2" "$3"; }
mk_only() { # FILE LABEL REMOVE-COMMAND ... a full state minus one thing
  local got; gate_full "$GT/g"; eval "$3"; got="$(gate_run "$1" "$GT/g/st")"
  [ "$got" != "0|BLOCKED|0" ] && ok "gate mutation: ${2} is caught (the copy was not BLOCKED: ${got})" || bad "gate mutation: ${2}" "the mutated copy still declared BLOCKED"
}
mkp m-nomarker.sh '[ -f "${P09_STATE}/p09-passed" ] || blocked' ': || blocked';   mk_only "$GT/tree/paths/m-nomarker.sh" "dropping the check that P09 ended PASS" 'rm -f "$GT/g/st/p09-passed"'
mkp m-noorigin.sh 'git -C "$SITE_REPO" remote get-url origin >/dev/null 2>&1 \' 'true \'; mk_only "$GT/tree/paths/m-noorigin.sh" "dropping the check for a remote named origin" 'git -C "$GT/g/site" remote remove origin'
# the sealing certificate is no longer a precondition (S00 meets it), so there is no check to drop; the guard is the other way
# round: a copy that BLOCKS on its absence again must be told apart by the "certificate absent, escrow runs" case (section 2b)
mkp m-certblock.sh 'CERT_FILE="${SITE_REPO}/${CERT_REL}"' 'CERT_FILE="${SITE_REPO}/${CERT_REL}"; [ -f "$CERT_FILE" ] || blocked "the site repository has no secrets/sealed-secrets-cert.pem"'
no_cert_run "$GT/tree/paths/m-certblock.sh" 2>/dev/null
if [ "${r#*|}" = BLOCKED ]; then ok "gate mutation: a copy that BLOCKS on an absent certificate again is told apart by the escrow case (it ends BLOCKED, the case above ends PASS)"
else bad "gate mutation: certificate block restored" "[${r}]"; fi
mkp m-defstate.sh 'P09_STATE="${TOCKMOX_P09_STATE:-}"' "P09_STATE=\"\${TOCKMOX_P09_STATE:-$GT/g/st}\""
gate_full "$GT/g"; got="$(gate_run "$GT/tree/paths/m-defstate.sh" "")"
[ "$got" != "0|BLOCKED|0" ] && ok "gate mutation: a default P09 state directory is caught (a stale one would be read as an install: ${got})" || bad "gate mutation: default state" "still BLOCKED"
# the refusal of an empty context: with it an empty context stops the path before any kubectl call; without it the path calls kubectl with an empty --context
gate_full "$GT/g"
got="$(gate_run "$P12" "$GT/g/st" KUBE_CONTEXT= TOCKMOX_P12_BUDGET=60)"
[ "${got%%|*}" != 0 ] && [ "${got##*|}" = 0 ] && ok "context: an empty KUBE_CONTEXT is refused before any cluster call" || bad "context: empty refused" "[${got}]"
mkp m-noctx.sh ': "${KUBE_CONTEXT:?KUBE_CONTEXT is empty: export the context of the cluster under test}"' 'KUBE_CONTEXT="${KUBE_CONTEXT:-}"'
gate_full "$GT/g"; got="$(gate_run "$GT/tree/paths/m-noctx.sh" "$GT/g/st" KUBE_CONTEXT= TOCKMOX_P12_BUDGET=60)"
[ "${got##*|}" != 0 ] && ok "context mutation: without the refusal the path reaches kubectl with an empty context (${got##*|} call(s)), so the refusal is what stops it" || bad "context mutation" "[${got}]"

# run.sh discovers P12 in P09's route group, after P11 (no cluster of its own)
DRY="$(env TOCKMOX_DRY_RUN=1 TOCKMOX_DOCS_REF=HEAD TOCKMOX_WORKDIR="$GT/w0" bash "${HERE}/run.sh" 2>&1)"
if printf '%s\n' "$DRY" | grep -E "group 'argocd-helm': .*P09-install-md-end-to-end.* P12-bring-your-own-ca" >/dev/null; then ok "run.sh: a run with no arguments discovers P12, in P09's route group (no extra cluster)"
else bad "run.sh: discovery" "$(printf '%s' "$DRY" | grep group | tr '\n' ';' | cut -c1-300)"; fi
cat > "$GT/bin/kubectl" <<STUB
#!/bin/sh
echo "\$@" >> "$GT/kcalls"
case "\$*" in *get-contexts*) echo stub-ctx ;; *"get nodes"*) printf True ;; *"version -o json"*) echo '{"serverVersion":{"gitVersion":"v1.33.0"}}' ;; esac
exit 0
STUB
echo "apiVersion: v1" > "$GT/kc"
rm -f "$GT/kcalls"
RUNOUT="$(env PATH="$GT/bin:$PATH" TOCKMOX_EXISTING_KUBECONFIG="$GT/kc" KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD \
          TOCKMOX_WORKDIR="$GT/w1" TOCKMOX_P09_STATE= bash "${HERE}/run.sh" P12 2>&1)"; RUNRC=$?
if [ "$RUNRC" = 4 ] && printf '%s\n' "$RUNOUT" | grep -F 'OUTCOME:  BLOCKED' >/dev/null \
   && printf '%s\n' "$RUNOUT" | grep -F 'UNCONVERTED    : 0' >/dev/null && printf '%s\n' "$RUNOUT" | grep -F 'paths blocked, NOT declared: 1' >/dev/null; then
  ok "run.sh: P12 named with no install declares BLOCKED; the run exits 4 (expected-outcomes.txt is read only in a run with no arguments), nothing UNCONVERTED"
else bad "run.sh: P12 with no install" "rc=${RUNRC}; $(printf '%s' "$RUNOUT" | tail -12 | tr '\n' ';' | cut -c1-400)"; fi
if ! grep -E 'secret|ingress|annotate|clusterissuer|certificate|pods -A' "$GT/kcalls" >/dev/null 2>&1; then ok "run.sh: P12 made no cluster read or write of its own"
else bad "run.sh: P12 made a cluster call" "$(grep -E 'secret|ingress|annotate|clusterissuer|certificate|pods -A' "$GT/kcalls" | head -3)"; fi

# ============================================================ 4. mutated copies lose their guards
mkdir -p "$TMP/mtree/paths"; ln -sfn "${HERE}/lib" "$TMP/mtree/lib"
# an expectation compared with itself can never go red: the ca.crt fingerprint row
mut "$P12" "$TMP/mtree/paths/m-selffp.sh" 'record "$S" "step 5: the ca.crt fingerprint read from the issued certificate'"'"'s Secret equals the generated CA'"'"'s" "$GEN_FP" "$(out_of "${S}-issued" | verdict fingerprint)"' \
  'record "$S" "step 5: the ca.crt fingerprint read from the issued certificate'"'"'s Secret equals the generated CA'"'"'s" "$(out_of "${S}-issued" | verdict fingerprint)" "$(out_of "${S}-issued" | verdict fingerprint)"'
setup_run "$RUN"; : > "$FX/knob-cacrt-other"
r="$(run_p12 "$TMP/mtree/paths/m-selffp.sh" "$RUN")"
if ! grep -F "RECORDED FAIL: step 5: the ca.crt fingerprint" "$TMP/out" >/dev/null; then ok "mutation: comparing the ca.crt fingerprint with itself loses the row, so the fixture's red row is the guard (outcome ${r#*|})"
else bad "mutation: self-compared fingerprint" "the row still failed"; fi
# the unsealed Secret compared with what the cluster says about itself
mut "$P12" "$TMP/mtree/paths/m-selfseal.sh" 'record "$S" "the unsealed ${SITE_SECRET} carries the generated CA'"'"'s certificate (fingerprint)" "$GEN_FP" \' \
  'record "$S" "the unsealed ${SITE_SECRET} carries the generated CA'"'"'s certificate (fingerprint)" "$(openssl x509 -in "${STATE}/${S}.unsealed.crt" -noout -fingerprint -sha256 2>/dev/null | verdict fingerprint)" \'
setup_run "$RUN"; : > "$FX/knob-unsealed-other"
r="$(run_p12 "$TMP/mtree/paths/m-selfseal.sh" "$RUN")"
if ! grep -F "RECORDED FAIL: the unsealed site-ca-root carries the generated CA's certificate" "$TMP/out" >/dev/null; then ok "mutation: reading the expected fingerprint back from the cluster loses the unsealed-certificate row"
else bad "mutation: self-compared unsealed" "the row still failed"; fi
# a path that stops reading the chain: the negative control and the verify rows are what see a certificate signed by the wrong CA
mut "$P12" "$TMP/mtree/paths/m-noverify.sh" 'openssl verify -CAfile "$CA_CRT" issued.crt 2>&1 | head -1' 'echo "issued.crt: OK"'
setup_run "$RUN"; : > "$FX/knob-leaf-chart"
r="$(run_p12 "$TMP/mtree/paths/m-noverify.sh" "$RUN")"
if ! grep -F "RECORDED FAIL: step 5: issued.crt verifies against the generated CA" "$TMP/out" >/dev/null; then ok "mutation: a harness re-read of the chain that cannot fail loses that row (the page's own output row still sees it)"
else bad "mutation: no verify" "the row still failed"; fi
# the negative control: without it, a verify that accepts everything would go unnoticed
mut "$P12" "$TMP/mtree/paths/m-noneg.sh" '&& echo accepted || echo rejected' '&& echo rejected || echo rejected'
setup_run "$RUN"
r="$(run_p12 "$TMP/mtree/paths/m-noneg.sh" "$RUN")"
[ "${r#*|}" = PASS ] && ok "mutation: the negative control is a real row (a copy that always says rejected still passes, so only its fixture tells them apart)" || bad "mutation: negative control" "[${r}]"
# the certificate table is read when it has settled: the first cluster run that read it did so 15 s after the push and
# found rows the page calls "still pending". Two reads show the old issuer here, then the table is good.
CERTROW='step 5: every Certificate row reads True and names site-ca'
setup_run "$RUN"; : > "$FX/knob-certs-late"; rm -f "$FX/cert-reads"
r="$(run_p12 "$P12" "$RUN" TOCKMOX_P12_REISSUE_WAIT=60 TOCKMOX_P12_POLL=1)"
if [ "${r#*|}" = PASS ] && grep -F "RECORDED PASS: ${CERTROW}" "$TMP/out" >/dev/null && [ "$(cat "$FX/cert-reads")" -eq 4 ]; then ok "certificates: rows still on the chart's issuer for two reads are waited for, and the page's block then reads a settled table ($(cat "$FX/cert-reads") reads)"
else bad "certificates: late rows" "[${r}] reads=$(cat "$FX/cert-reads" 2>/dev/null) $(grep -F "$CERTROW" "$TMP/out" | head -2 | tr '\n' ';' | cut -c1-300)"; fi
setup_run "$RUN"; : > "$FX/knob-certs-late"; rm -f "$FX/cert-reads"
r="$(run_p12 "$P12" "$RUN")"
if grep -F "RECORDED FAIL: ${CERTROW}" "$TMP/out" >/dev/null; then ok "certificates: with no time allowed the same late table is red, so the wait is what the case above shows"
else bad "certificates: late rows, no wait" "[${r}] the row did not fail"; fi
setup_run "$RUN"
r="$(run_p12 "$P12" "$RUN")"
if [ "${r#*|}" = PASS ] && grep -F "rows on an issuer of their own, which the page allows for barman-cloud-client,barman-cloud-server: 2 on their own issuer: barman-cloud-client, barman-cloud-server" "$TMP/out" >/dev/null; then ok "certificates: the backup plugin's two rows on their own issuer pass, and the report names them"
else bad "certificates: own-issuer rows" "[${r}] $(grep -F 'rows on an issuer of their own' "$TMP/out" | head -1 | cut -c1-300)"; fi
mut "$P12" "$TMP/mtree/paths/m-noown.sh" 'OWN_ISSUER_CERTS="barman-cloud-client,barman-cloud-server"' 'OWN_ISSUER_CERTS=""'
setup_run "$RUN"
r="$(run_p12 "$TMP/mtree/paths/m-noown.sh" "$RUN")"
if grep -F "RECORDED FAIL: ${CERTROW}" "$TMP/out" >/dev/null; then ok "mutation: without the page's exception the backup plugin's two rows turn the certificate row red (what the cluster showed)"
else bad "mutation: no exception" "[${r}] the row did not fail"; fi
# the placeholder order: YOUR_TLS_SECRET_NAME is a prefix of YOUR_TLS_SECRET_NAMESPACE, and the first cluster run that
# reached block 9 pasted "<secret>SPACE" as the namespace. The row reads both values back out of the block that is pasted.
PHROW='GLUE: the block is pasted with TLS_NS and TLS_SECRET set to the namespace and Secret chosen, whole'
setup_run "$RUN"
r="$(run_p12 "$P12" "$RUN")"
if [ "${r#*|}" = PASS ] && grep -F "RECORDED PASS: ${PHROW}" "$TMP/out" >/dev/null; then ok "placeholders: block 9 is pasted with the namespace and the Secret whole, and the row says so"
else bad "placeholders: block 9" "[${r}] $(grep -F "$PHROW" "$TMP/out" | head -2 | tr '\n' ';' | cut -c1-300)"; fi
mut "$P12" "$TMP/mtree/paths/m-phorder.sh" 'BT="${BT//YOUR_TLS_SECRET_NAMESPACE/${TLS_NS_V:-NO_TLS_NAMESPACE}}"; BT="${BT//YOUR_TLS_SECRET_NAME/${TLS_SECRET_V:-NO_TLS_SECRET}}"' \
  'BT="${BT//YOUR_TLS_SECRET_NAME/${TLS_SECRET_V:-NO_TLS_SECRET}}"; BT="${BT//YOUR_TLS_SECRET_NAMESPACE/${TLS_NS_V:-NO_TLS_NAMESPACE}}"'
setup_run "$RUN"
r="$(run_p12 "$TMP/mtree/paths/m-phorder.sh" "$RUN")"
if grep -F "RECORDED FAIL: ${PHROW}" "$TMP/out" >/dev/null; then ok "mutation: replacing the shorter placeholder first (the namespace becomes <secret>SPACE) turns the placeholder row red"
else bad "mutation: placeholder order" "[${r}] the row did not fail"; fi
# the page's blocks are pasted into zsh, which refuses a command holding an unquoted [..] that matches no file ("no matches
# found"); bash passes it through, so nothing hermetic saw step 5's custom-columns line until a cluster run did
blocks_of() { awk '/^```bash$/ { f = 1; next } /^```$/ { f = 0 } f' "$1"; }
PAGE_MD="${REPO}/docs/administration/bring-your-own-ca.md"
[ "$(blocks_of "$PAGE_MD" | v globsafe)" = safe ] && ok "zsh: no bash block of the page holds an unquoted [..] pattern" || bad "zsh: the page's blocks" "$(blocks_of "$PAGE_MD" | v globsafe | cut -c1-300)"
[ "$(blocks_of "$PAGE_MD" | sed "s/-o 'custom-columns=\(.*\)'\$/-o custom-columns=\1/" | v globsafe | cut -c1-17)" = "unquoted pattern:" ] \
  && ok "zsh: the same blocks with step 5's custom-columns argument unquoted, as it was, are flagged" || bad "zsh: unquoted custom-columns" "not flagged"
[ "$(printf '%s\n' 'if [ -f "$x" ]; then echo "${a[0]}" "b[1]"; fi' "kubectl get x -o jsonpath='{.items[0].metadata.name}'" | v globsafe)" = safe ] \
  && ok "zsh: test brackets, \${a[0]} and quoted words are not flagged" || bad "zsh: false positive" "$(printf '%s\n' 'if [ -f "$x" ]; then echo "${a[0]}" "b[1]"; fi' | v globsafe)"
[ "$(printf '%s\n' 'kubectl get x -o jsonpath={.items[0].metadata.name}' | v globsafe)" = "unquoted pattern: jsonpath={.items[0].metadata.name}" ] \
  && ok "zsh: an unquoted jsonpath with an index is flagged, and the word is named" || bad "zsh: unquoted jsonpath" "$(printf '%s\n' 'kubectl get x -o jsonpath={.items[0].metadata.name}' | v globsafe)"
# the fixture that makes a verify accept everything: a CA that signed nothing shown as accepted
setup_run "$RUN"; : > "$FX/knob-leaf-chart"
mkdir -p "$TMP/bin-acc"; cat > "$TMP/bin-acc/openssl" <<'ACC'
#!/usr/bin/env bash
real=/usr/bin/openssl
case "$1" in verify) echo "issued.crt: OK"; exit 0 ;; esac
exec "$real" "$@"
ACC
chmod +x "$TMP/bin-acc/openssl"
r="$(run_p12 "$P12" "$RUN" PATH="$TMP/bin-acc:$FX/bin:$PATH")"
if grep -F "RECORDED FAIL: step 5: issued.crt does not verify against the chart's own CA" "$TMP/out" >/dev/null; then ok "planted: an openssl verify that accepts everything turns the negative-control row red"
else bad "planted: accept-everything verify" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-100 | head -3 | tr '\n' ';')"; fi

# a path that runs the blocks from the site repository would leave issued.crt there: the two rows see it
mut "$P12" "$TMP/mtree/paths/m-cwd.sh" 'cd "${STATE}/work"' 'cd "$SITE_REPO"'
setup_run "$RUN"
r="$(run_p12 "$TMP/mtree/paths/m-cwd.sh" "$RUN")"
if grep -F "RECORDED FAIL: block 9's issued.crt was written to the scratch directory" "$TMP/out" >/dev/null && grep -F "RECORDED FAIL: the site repository clone holds nothing" "$TMP/out" >/dev/null; then ok "mutation: running the blocks from the site repository turns the scratch-directory row and the clean-clone row red"
else bad "mutation: cwd in the site repository" "[${r}] $(grep '^RECORDED FAIL' "$TMP/out" | cut -c1-100 | head -3 | tr '\n' ';')"; fi

# ============================================================ 5. the lane's switch
# p09-lane.sh runs unmodified beside stubs of what it calls; run.sh logs each path it is asked for.
L="$TMP/ltree/tests/executed-docs"; mkdir -p "$L/provision" "$TMP/lbin"
cp "${HERE}/p09-lane.sh" "$L/p09-lane.sh"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$LANE_LOG"
case "$1" in
  create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;;
  publish) echo node.stub.invalid:31234 ;;
  guard-file) echo "$LANE_TMP/guard" ;;
esac
STUB
printf '#!/usr/bin/env bash\necho "site-repo-server $*" >> "$LANE_LOG"\n[ "$1" = url ] && echo http://site-repo.stub/tockmox.git\n[ "$1" = nodeport ] && echo 30418\nexit 0\n' > "$L/provision/site-repo-server.sh"
cat > "$L/run.sh" <<'STUB'
#!/usr/bin/env bash
# a stub run.sh: logs the call, writes the receipt a real one would ("OUTCOME reason"), exits as told
echo "run.sh $*" >> "$LANE_LOG"
case "$1" in
  P09) name=P09-install-md-end-to-end; out="${STUB_P09_OUT:-PASS}"; rc="${STUB_P09_RC:-0}" ;;
  P11) name=P11-fresh-install-recovery; out="${STUB_P11_OUT:-PASS}"; rc="${STUB_P11_RC:-0}" ;;
  P12) name=P12-bring-your-own-ca; out="${STUB_P12_OUT:-PASS}"; rc="${STUB_P12_RC:-0}" ;;
  P13) name=P13-planted-faults; out="${STUB_P13_OUT:-PASS}"; rc="${STUB_P13_RC:-0}" ;;
  *) exit 0 ;;
esac
n="$(ls "$TOCKMOX_WORKDIR" | grep -c '^receipts-')"
d="$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))"; mkdir -p "$d"
[ "$out" = NONE ] || printf '%s a stub reason\n' "$out" > "$d/$name"
exit "$rc"
STUB
# git is a stub here (the external route's reachability probe would otherwise dial a name that does not exist);
# remote-route-test.sh runs the real git against a real daemon
for t in helm kubeseal openssl zsh curl age age-keygen git; do printf '#!/bin/sh\nexit 0\n' > "$TMP/lbin/$t"; done
cat > "$TMP/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in *"config current-context"*) echo stub-guest ;; *"get nodes"*) echo node.stub.invalid ;; esac
STUB
chmod +x "$TMP/lbin"/* "$L/provision"/*.sh "$L/run.sh"
LN=0
run_lane() { # VAR=value... -> output in $TMP/lout, status in $LRC, the calls in $LH/log
  LN=$((LN+1)); LH="$TMP/lane-$LN"; mkdir -p "$LH/home" "$LH/work"; : > "$LH/log"
  env -u TOCKMOX_P09_BYO_CA -u TOCKMOX_KEEP_CLUSTER -u TOCKMOX_P09_ROUTE "$@" HOME="$LH/home" TOCKMOX_WORKDIR="$LH/work" LANE_LOG="$LH/log" LANE_TMP="$LH" PATH="$TMP/lbin:$PATH" \
    KUBECONFIG="$LH/substrate.kubeconfig" TOCKMOX_DOCS_REF=stub TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate TOCKMOX_TEST_VM=ed-lane \
    bash "$L/p09-lane.sh" > "$TMP/lout" 2>&1
  LRC=$?
}
ran12() { grep -c '^run.sh P12' "$LH/log"; }
SKIPLINE() { grep -F "lane 7: P12 (a supplied CA) skipped: $1" "$TMP/lout" >/dev/null; }
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_KEEP_CLUSTER=0
[ "$LRC" = 0 ] && [ "$(ran12)" = 1 ] && ok "lane: auto, external route, not kept: P12 runs" || bad "lane: auto+external+unkept" "rc=$LRC $(tr '\n' ';' < "$LH/log")"
awk '/^run.sh P11/{a=NR} /^run.sh P12/{b=NR} END{exit !(a && b && a<b)}' "$LH/log" && ok "lane: P11 runs first, then P12" || bad "lane: order" "$(tr '\n' ';' < "$LH/log")"
awk '/^run.sh P12/{b=NR} /^run.sh P13/{c=NR} END{exit !(b && c && b<c)}' "$LH/log" && ok "lane: P13 runs last, after P12 (P13 breaks the install on purpose)" || bad "lane: P13 after P12" "$(tr '\n' ';' < "$LH/log")"
run_lane TOCKMOX_P09_ROUTE=external
[ "$LRC" = 0 ] && [ "$(ran12)" = 1 ] && ok "lane: auto with TOCKMOX_KEEP_CLUSTER unset runs P12" || bad "lane: auto+unset keep" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_BYO_CA=auto
[ "$LRC" = 0 ] && [ "$(ran12)" = 1 ] && ok "lane: the word auto is the default" || bad "lane: auto word" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_BYO_CA=
[ "$LRC" = 0 ] && [ "$(ran12)" = 1 ] && ok "lane: an empty value is the default too" || bad "lane: empty" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=built-in
[ "$LRC" = 0 ] && [ "$(ran12)" = 0 ] && SKIPLINE "built-in route: the page's commit cannot be delivered, because the forge's main takes pull requests only" \
  && ok "lane: auto on the built-in route skips P12 with the reason" || bad "lane: auto+built-in" "rc=$LRC $(grep 'lane 7' "$TMP/lout")"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_KEEP_CLUSTER=1
[ "$LRC" = 0 ] && [ "$(ran12)" = 0 ] && SKIPLINE "kept run: P12 replaces the install's CA and a kept install is left as the reader expects it" \
  && ok "lane: auto on a kept run skips P12 with the reason" || bad "lane: auto+kept" "rc=$LRC $(grep 'lane 7' "$TMP/lout")"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_BYO_CA=0
[ "$LRC" = 0 ] && [ "$(ran12)" = 0 ] && SKIPLINE "TOCKMOX_P09_BYO_CA=0" && ok "lane: 0 never runs P12" || bad "lane: 0" "rc=$LRC $(grep 'lane 7' "$TMP/lout")"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_KEEP_CLUSTER=1 TOCKMOX_P09_BYO_CA=1
[ "$LRC" = 0 ] && [ "$(ran12)" = 1 ] && ok "lane: 1 runs P12 even on a kept run (an explicit request)" || bad "lane: 1+kept" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=built-in TOCKMOX_P09_BYO_CA=1
[ "$LRC" = 2 ] && ! grep -x create "$LH/log" >/dev/null && ! grep '^run.sh' "$LH/log" >/dev/null && ok "lane: 1 on the built-in route is refused (exit 2) before anything is created" || bad "lane: 1+built-in" "rc=$LRC $(tr '\n' ';' < "$LH/log")"
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_P09_BYO_CA=yes
[ "$LRC" = 2 ] && ! grep -x create "$LH/log" >/dev/null && grep -F 'must be auto, 1 or 0, not: yes' "$TMP/lout" >/dev/null && ok "lane: a garbage value is refused (exit 2) before anything is created" || bad "lane: garbage" "rc=$LRC $(tr '\n' ';' < "$LH/log")"
run_lane TOCKMOX_P09_ROUTE=external STUB_P09_RC=1
[ "$LRC" = 1 ] && [ "$(ran12)" = 0 ] && ok "lane: a P09 that failed means P12 does not run" || bad "lane: P09 failed" "rc=$LRC $(tr '\n' ';' < "$LH/log")"
run_lane TOCKMOX_P09_ROUTE=external STUB_P12_RC=1
[ "$LRC" = 1 ] && ok "lane: a P12 failure is the lane's exit when nothing earlier failed" || bad "lane: P12 fails" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external STUB_P11_RC=4 STUB_P12_RC=1
[ "$LRC" = 4 ] && [ "$(ran12)" = 1 ] && ok "lane: P12 still runs after a failed P11, and the exit stays P11's" || bad "lane: P11 fails" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external STUB_P12_OUT=BLOCKED
[ "$LRC" = 4 ] && grep -F 'lane: P12-bring-your-own-ca declared BLOCKED: a stub reason' "$TMP/lout" >/dev/null && ok "lane: a P12 that exited 0 but declared BLOCKED fails the lane with 4 and names it" || bad "lane: P12 BLOCKED" "rc=$LRC $(tail -2 "$TMP/lout")"
run_lane TOCKMOX_P09_ROUTE=external STUB_P12_OUT=NONE
[ "$LRC" = 1 ] && ok "lane: a P12 that left no receipt fails the lane with 1" || bad "lane: P12 no receipt" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external STUB_P11_RC=4 STUB_P12_OUT=BLOCKED
[ "$LRC" = 4 ] && ok "lane: an earlier P11 failure keeps its status over a later P12 outcome" || bad "lane: P11 then P12" "rc=$LRC"
run_lane TOCKMOX_P09_ROUTE=external STUB_P09_OUT=BLOCKED
[ "$LRC" = 4 ] && [ "$(ran12)" = 0 ] && ok "lane: a P09 that declared BLOCKED means P12 does not run (and the lane exits 4)" || bad "lane: P09 BLOCKED" "rc=$LRC ran $(ran12)"
# mutated lanes lose their guards
mut "${HERE}/p09-lane.sh" "$L/p09-lane.sh" 'elif [ "$KEEP" = 1 ]; then' 'elif false; then'
run_lane TOCKMOX_P09_ROUTE=external TOCKMOX_KEEP_CLUSTER=1
[ "$(ran12)" = 1 ] && ok "lane mutation: without the kept-run check P12 runs on a kept install, so the kept-run case above is the guard" || bad "lane mutation: keep" "ran $(ran12)"
mut "${HERE}/p09-lane.sh" "$L/p09-lane.sh" 'if [ "$p12_rc" != 0 ] && [ "$rc" = 0 ]; then' 'if [ "$p12_rc" != 0 ]; then'
run_lane TOCKMOX_P09_ROUTE=external STUB_P11_RC=4 STUB_P12_RC=1
[ "$LRC" = 1 ] && ok "lane mutation: letting P12 overwrite an earlier failure changes the exit (1, not 4), so the ordering case above is the guard" || bad "lane mutation: exit" "rc=$LRC"
mut "${HERE}/p09-lane.sh" "$L/p09-lane.sh" 'if [ "$p12_code" != 0 ] && [ "$rc" = 0 ]; then' 'if false; then'
run_lane TOCKMOX_P09_ROUTE=external STUB_P12_OUT=BLOCKED
[ "$LRC" = 0 ] && ok "lane mutation: without the P12 outcome check a BLOCKED P12 ends 0, so the P12 outcome case above is the guard" || bad "lane mutation: P12 outcome" "rc=$LRC"
mut "${HERE}/p09-lane.sh" "$L/p09-lane.sh" '[ "$ROUTE" = external ] || refuse "TOCKMOX_P09_BYO_CA=1' ': || refuse "TOCKMOX_P09_BYO_CA=1'
run_lane TOCKMOX_P09_ROUTE=built-in TOCKMOX_P09_BYO_CA=1
[ "$LRC" != 2 ] && ok "lane mutation: without the up-front refusal the built-in lane is created ($(grep -cx create "$LH/log") create), so the refusal case above is the guard" || bad "lane mutation: refusal" "rc=$LRC"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

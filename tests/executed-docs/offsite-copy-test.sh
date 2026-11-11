#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic test for the off-site copy of a p09 throwaway (TOCKMOX_P09_OFFSITE=git):
# throwaway-cluster.sh offsite-check and offsite-repo, destroy and sweep deleting
# the repository, lib/p09-offsite.sh (the block edit and the scrub P09 uses), and
# the lane's steps around them. No cluster and no forge: kubectl is a stub that
# keeps Secrets as files and logs calls, curl is a stub forge API that logs what
# it was asked and whether the token was on its command line, and the
# provisioner, the library and the lane run unmodified.
#
#   1. offsite-check reads the settings Secret, refuses one it cannot get or use,
#      naming the key and never its value
#   2. offsite-repo creates ORG/VM as the token's user and writes what the
#      installer takes; the marker is written first; nothing is created for a VM
#      that does not exist; the forge's name and the token are never printed, and
#      the token is never on a command line
#   3. destroy and sweep delete the repository of a VM that has one, call nothing
#      for a VM that has none, and fail, naming the repository, when it stays
#   4. the block edit adds the destination to install.md's own command, by
#      variable name; the scrub takes the host out of a transcript
#   5. the lane checks before it creates, exports the destination to P09, adds the
#      CA to ArgoCD's trust, refuses what cannot work, and leaves no token behind
#
#   ./tests/executed-docs/offsite-copy-test.sh
#   TC=/path/to/throwaway-cluster.sh LANE_SH=/path/to/p09-lane.sh ./tests/executed-docs/offsite-copy-test.sh
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # stub bodies and greps are literal text
# shellcheck disable=SC1003  # a pattern that ends in a backslash is meant: it is the block's line continuation
# shellcheck disable=SC2012  # the names listed are the provisioner's own six, all plain
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
TC="${TC:-${HERE}/provision/throwaway-cluster.sh}"
LANE_SH="${LANE_SH:-${HERE}/p09-lane.sh}"
LIB="${OFFSITE_LIB:-${HERE}/lib/p09-offsite.sh}"
P09="${P09:-${HERE}/paths/P09-install-md-end-to-end.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

FORGE_HOST=forge.example.internal
TOKEN=stub.token.0123456789abcdef
PEM='-----BEGIN CERTIFICATE-----
c3R1Yg==
-----END CERTIFICATE-----'

mkdir -p "$TMP/bin" "$TMP/work"
cat > "$TMP/bin/kubectl" <<'STUB'
#!/usr/bin/env python3
# Secrets are directories of files under $KT_STORE/secrets; VMs are rows of $KT_STORE/vms.
import base64, json, os, shutil, sys
with open(os.environ["KT_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
a = [x for x in sys.argv[1:] if not x.startswith("--context=")]
if "-n" in a:
    i = a.index("-n"); del a[i:i + 2]
store = os.environ["KT_STORE"]
sec = os.path.join(store, "secrets"); vms = os.path.join(store, "vms")
fail = os.environ.get("KT_FAIL", "").split()
def rows():
    return [l.split() for l in open(vms) if l.strip()] if os.path.exists(vms) else []
def stop(msg):
    sys.stderr.write("Error from server (%s)\n" % msg); sys.exit(1)
if a[:2] == ["get", "vm"]:
    if len(a) > 2 and not a[2].startswith("-"):
        sys.exit(0) if any(r[0] == a[2] for r in rows()) else stop('NotFound): virtualmachine "%s" not found' % a[2])
    wide = any("creationTimestamp" in x for x in a)
    for r in rows():
        print(" ".join(r) if wide else r[0])
elif a[:2] == ["delete", "vm"]:
    keep = [r for r in rows() if r[0] != a[2]]
    open(vms, "w").write("".join(" ".join(r) + "\n" for r in keep))
elif a[:2] == ["get", "secret"]:
    if len(a) < 3 or a[2].startswith("-"):
        for n in sorted(os.listdir(sec)):
            if "-l" not in a or os.path.exists(os.path.join(sec, n, ".labels")):
                print(n)
        sys.exit(0)
    d = os.path.join(sec, a[2])
    if "get-" + a[2] in fail:
        stop('Forbidden): secrets "%s" is forbidden: User "system:serviceaccount:tockmox-test:stub" cannot get resource "secrets"' % a[2])
    if not os.path.isdir(d):
        stop('NotFound): secrets "%s" not found' % a[2])
    fmt = a[a.index("-o") + 1] if "-o" in a else ""
    keys = [k for k in os.listdir(d) if not k.startswith(".")]
    if fmt == "name":
        print("secret/" + a[2])
    elif fmt == "json":
        print(json.dumps({"kind": "Secret", "data": {k: base64.b64encode(open(os.path.join(d, k), "rb").read()).decode() for k in keys}}))
    elif fmt.startswith("jsonpath={.data."):
        p = os.path.join(d, fmt[len("jsonpath={.data."):-1])
        if os.path.exists(p):
            sys.stdout.write(base64.b64encode(open(p, "rb").read()).decode())
elif a[:2] == ["delete", "secret"]:
    for n in [x for x in a[2:] if not x.startswith("-")]:
        if os.path.isdir(os.path.join(sec, n)):
            shutil.rmtree(os.path.join(sec, n)); print('secret "%s" deleted' % n)
elif a[:3] == ["create", "secret", "generic"]:
    if "create-secret" in fail:
        stop("Forbidden): secrets is forbidden")
    d = os.path.join(sec, a[3]); os.makedirs(d)
    for x in a[4:]:
        if x.startswith("--from-literal="):
            k, v = x[len("--from-literal="):].split("=", 1)
            open(os.path.join(d, k), "w").write(v)
elif a[:2] == ["label", "secret"]:
    open(os.path.join(sec, a[2], ".labels"), "w").write(" ".join(a[3:]))
elif a[:1] == ["api-resources"]:
    print("virtualmachines   vm,vms   kubevirt.io/v1   true   VirtualMachine")
STUB
# The forge's API. It reads the address and the token where the provisioner must put them, the
# --config file, logs "METHOD URL data token-in-config token-on-argv", and answers as CURL_* say.
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env python3
import os, re, sys
a = sys.argv[1:]
def opt(name):
    return a[a.index(name) + 1] if name in a else ""
cfg = open(opt("--config")).read() if "--config" in a else ""
url = (re.search(r'^url = "(.*)"$', cfg, re.M) or [None, ""])[1]
tok = os.environ["STUB_TOKEN"]
method = opt("-X") or "GET"
with open(os.environ["CURL_LOG"], "a") as f:
    f.write("%s %s data=%s cfgtoken=%s argvtoken=%s cacert=%s\n" % (
        method, url, opt("--data") or "-", "yes" if ("Authorization: token " + tok) in cfg else "no",
        "yes" if any(tok in x for x in a) else "no", "yes" if "cacert = " in cfg else "no"))
path = re.sub(r"^https://[^/]+", "", url)
code, body = "404", "{}"
if method == "GET" and path == "/api/v1/user":
    code, body = os.environ.get("CURL_USER_CODE", "200"), '{"login": "stub-bot"}'
elif method == "POST" and re.fullmatch(r"/api/v1/orgs/[^/]+/repos", path):
    code = os.environ.get("CURL_CREATE_CODE", "201")
elif method == "DELETE" and path.startswith("/api/v1/repos/"):
    code = os.environ.get("CURL_DELETE_CODE", "204")
if code == "000":
    sys.stderr.write("curl: (6) Could not resolve host: %s\n" % re.sub(r"^https://([^/:]+).*", r"\1", url)); sys.exit(int(os.environ.get("CURL_EXIT", "6")))
if opt("-o"):
    open(opt("-o"), "w").write(body)
sys.stdout.write(code)
STUB
chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl"

stamp() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
now="$(date -u +%s)"; OLD="$(stamp -300)"
settings() {  # url org token ca -> the Secret p09-offsite; an empty argument leaves the key out
  local d="$TMP/store/secrets/p09-offsite"; rm -rf "$d"; mkdir -p "$d"
  [ -z "$1" ] || printf '%s' "$1" > "$d/url"
  [ -z "$2" ] || printf '%s' "$2" > "$d/org"
  [ -z "$3" ] || printf '%s' "$3" > "$d/token"
  [ -z "$4" ] || printf '%s\n' "$4" > "$d/ca.crt"
}
reset_store() {
  rm -rf "$TMP/store" "$TMP/work"; mkdir -p "$TMP/store/secrets" "$TMP/work"; : > "$TMP/log"; : > "$TMP/curl.log"
  printf 'ed-run %s <none>\n' "$OLD" > "$TMP/store/vms"
  settings "https://${FORGE_HOST}/" ed-offsite "$TOKEN" "$PEM"
}
has_secret() { [ -d "$TMP/store/secrets/$1" ]; }
run_tc() {  # verb args... -> stdout in $TMP/out, stderr in $TMP/err, status in $RC
  KT_LOG="$TMP/log" KT_STORE="$TMP/store" CURL_LOG="$TMP/curl.log" STUB_TOKEN="$TOKEN" PATH="$TMP/bin:$PATH" TMPDIR="$TMP/work" \
    TOCKMOX_SUBSTRATE_CONTEXT=stub TOCKMOX_TEST_NAMESPACE=tockmox-test TOCKMOX_TEST_VM="${VM:-ed-run}" \
    bash "$TC" "$@" > "$TMP/out" 2> "$TMP/err"
  RC=$?
}
both() { cat "$TMP/out" "$TMP/err"; }
quiet() { ! both | grep -F -e "$FORGE_HOST" -e "$TOKEN" >/dev/null; }

# ---------------------------------------------------------------------------
# 1. offsite-check
reset_store; run_tc offsite-check
[ "$RC" = 0 ] && [ "$(cat "$TMP/out")" = ca ] && ok "offsite-check reads the settings and reports a private CA" \
  || bad "offsite-check reads the settings and reports a private CA" "rc=$RC $(both | tail -3)"
quiet && ok "offsite-check prints neither the forge's name nor the token" || bad "offsite-check prints neither the forge's name nor the token" "$(both)"
[ -z "$(find "$TMP/work" -type f 2>/dev/null)" ] && ok "offsite-check leaves no file behind" || bad "offsite-check leaves no file behind" "$(find "$TMP/work" -type f)"
reset_store; settings "https://${FORGE_HOST}:8443" ed-offsite "$TOKEN" ""; run_tc offsite-check
[ "$RC" = 0 ] && [ "$(cat "$TMP/out")" = no-ca ] && ok "offsite-check reports no CA when the Secret has none, and takes a port" \
  || bad "offsite-check reports no CA when the Secret has none, and takes a port" "rc=$RC $(both | tail -3)"
reset_store; KT_FAIL=get-p09-offsite run_tc offsite-check
[ "$RC" = 2 ] && grep -F "REFUSING: this credential cannot 'get' the Secret tockmox-test/p09-offsite" "$TMP/err" >/dev/null \
  && ok "a credential that cannot get the Secret is refused, naming the Secret and the verb" \
  || bad "a credential that cannot get the Secret is refused, naming the Secret and the verb" "rc=$RC $(both | tail -3)"
reset_store; rm -rf "$TMP/store/secrets/p09-offsite"; run_tc offsite-check
[ "$RC" = 2 ] && ok "a Secret that does not exist is refused" || bad "a Secret that does not exist is refused" "rc=$RC $(both | tail -3)"
for u in "http://${FORGE_HOST}" "https://${FORGE_HOST}/some/path" "https://user:pw@${FORGE_HOST}" ""; do
  reset_store; settings "$u" ed-offsite "$TOKEN" "$PEM"; run_tc offsite-check
  [ "$RC" = 2 ] && grep -F 'key url must be https://HOST' "$TMP/err" >/dev/null && quiet \
    && ok "url '${u/$FORGE_HOST/HOST}' is refused by key name, without printing it" \
    || bad "url '${u/$FORGE_HOST/HOST}' is refused by key name, without printing it" "rc=$RC $(both | tail -3)"
done
reset_store; settings "https://${FORGE_HOST}" "bad org" "$TOKEN" "$PEM"; run_tc offsite-check
[ "$RC" = 2 ] && grep -F 'key org must be' "$TMP/err" >/dev/null && ok "an org that is not a name is refused" || bad "an org that is not a name is refused" "rc=$RC $(both | tail -3)"
reset_store; settings "https://${FORGE_HOST}" ed-offsite "" "$PEM"; run_tc offsite-check
[ "$RC" = 2 ] && grep -F 'key token must be' "$TMP/err" >/dev/null && ok "a missing token is refused" || bad "a missing token is refused" "rc=$RC $(both | tail -3)"
reset_store; settings "https://${FORGE_HOST}" ed-offsite "$TOKEN" "not a certificate"; run_tc offsite-check
[ "$RC" = 2 ] && grep -F 'key ca.crt holds no PEM certificate' "$TMP/err" >/dev/null && ok "a ca.crt that is not PEM is refused" || bad "a ca.crt that is not PEM is refused" "rc=$RC $(both | tail -3)"

# ---------------------------------------------------------------------------
# 2. offsite-repo
reset_store; run_tc offsite-repo "$TMP/off"
[ "$RC" = 0 ] && grep -F "POST https://${FORGE_HOST}/api/v1/orgs/ed-offsite/repos data={\"name\": \"ed-run\", \"private\": true, \"auto_init\": false}" "$TMP/curl.log" >/dev/null \
  && ok "offsite-repo creates ORG/VM, private and empty, on the forge the Secret names" \
  || bad "offsite-repo creates ORG/VM, private and empty, on the forge the Secret names" "rc=$RC $(cat "$TMP/curl.log") $(both | tail -3)"
[ "$(cat "$TMP/off/git-url" 2>/dev/null)" = "https://${FORGE_HOST}/ed-offsite/ed-run.git" ] && [ "$(cat "$TMP/off/host" 2>/dev/null)" = "$FORGE_HOST" ] \
  && ok "it writes the repository's URL and the forge's host for the lane" || bad "it writes the repository's URL and the forge's host for the lane" "$(ls "$TMP/off" 2>&1)"
[ "$(cat "$TMP/off/git-credentials" 2>/dev/null)" = "stub-bot
$TOKEN" ] && ok "git-credentials is the token's user, then the token: the two lines the installer takes" \
  || bad "git-credentials is the token's user, then the token: the two lines the installer takes" "$(wc -l < "$TMP/off/git-credentials" 2>&1)"
grep -F -e '-----BEGIN CERTIFICATE-----' "$TMP/off/ca.crt" >/dev/null 2>&1 && ok "it writes the forge's CA" || bad "it writes the forge's CA" "$(ls "$TMP/off" 2>&1)"
modes="$(python3 -c 'import os,sys; d=sys.argv[1]; print(oct(os.stat(d).st_mode & 0o777), " ".join(sorted(set(oct(os.stat(os.path.join(d,f)).st_mode & 0o777) for f in os.listdir(d)))))' "$TMP/off" 2>/dev/null)"
[ "$modes" = "0o700 0o600" ] && [ "$(ls "$TMP/off" | tr '\n' ' ')" = "ca.crt git-credentials git-url host org url " ] \
  && ok "the directory is the caller's alone and holds nothing else (no bare token, no curl config)" \
  || bad "the directory is the caller's alone and holds nothing else (no bare token, no curl config)" "$modes: $(ls "$TMP/off" 2>&1 | tr '\n' ' ')"
[ "$(cat "$TMP/store/secrets/ed-run-offsite/repo" 2>/dev/null)" = ed-offsite/ed-run ] && [ -f "$TMP/store/secrets/ed-run-offsite/.labels" ] \
  && ok "the marker Secret <VM>-offsite names the repository and carries the harness label" \
  || bad "the marker Secret <VM>-offsite names the repository and carries the harness label" "$(ls -A "$TMP/store/secrets")"
[ "$(grep -c 'cfgtoken=yes argvtoken=no cacert=yes' "$TMP/curl.log")" = "$(grep -c . "$TMP/curl.log")" ] && [ "$(grep -c . "$TMP/curl.log")" = 2 ] \
  && ok "every call carries the token and the CA in curl's config file, and none has the token on its command line" \
  || bad "every call carries the token and the CA in curl's config file, and none has the token on its command line" "$(cat "$TMP/curl.log")"
quiet && [ "$(cat "$TMP/out")" = "$TMP/off" ] && ok "offsite-repo prints the directory and neither the forge's name nor the token" \
  || bad "offsite-repo prints the directory and neither the forge's name nor the token" "$(both)"
reset_store; CURL_CREATE_CODE=409 run_tc offsite-repo "$TMP/off"
[ "$RC" = 0 ] && [ -s "$TMP/off/git-url" ] && ok "a repository an earlier attempt already made is used" || bad "a repository an earlier attempt already made is used" "rc=$RC $(both | tail -3)"
reset_store; CURL_CREATE_CODE=403 run_tc offsite-repo "$TMP/off"
[ "$RC" = 1 ] && [ ! -e "$TMP/off" ] && grep -F 'answered 403' "$TMP/err" >/dev/null && quiet \
  && ok "a refused create fails with the status, leaves no directory, and names no host" \
  || bad "a refused create fails with the status, leaves no directory, and names no host" "rc=$RC $(both | tail -3)"
has_secret ed-run-offsite && ok "the marker stays after a failed create, so destroy still looks for the repository" \
  || bad "the marker stays after a failed create, so destroy still looks for the repository" "$(ls -A "$TMP/store/secrets")"
reset_store; CURL_USER_CODE=401 run_tc offsite-repo "$TMP/off"
[ "$RC" = 1 ] && ! grep '^POST' "$TMP/curl.log" >/dev/null && ! has_secret ed-run-offsite && grep -F 'did not accept key token' "$TMP/err" >/dev/null \
  && ok "a token the forge does not accept fails before anything is created" || bad "a token the forge does not accept fails before anything is created" "rc=$RC $(both | tail -3)"
reset_store; CURL_USER_CODE=403 run_tc offsite-repo "$TMP/off"
[ "$RC" = 0 ] && grep '^POST' "$TMP/curl.log" >/dev/null && [ "$(cat "$TMP/off/git-credentials" 2>/dev/null)" = "git
$TOKEN" ] && ok "a token without read:user still creates the repository, and the credentials file names a user the forge ignores" \
  || bad "a token without read:user still creates the repository, and the credentials file names a user the forge ignores" "rc=$RC $(both | tail -3)"
reset_store; CURL_USER_CODE=000 run_tc offsite-repo "$TMP/off"
[ "$RC" = 1 ] && quiet && grep -F 'answered 000, curl exit 6: the host in key url did not resolve' "$TMP/err" >/dev/null \
  && ok "a forge that is not reached fails with curl's exit code and its meaning, not curl's own words, which name the host" \
  || bad "a forge that is not reached fails with curl's exit code and its meaning, not curl's own words, which name the host" "rc=$RC $(both | tail -3)"
reset_store; CURL_USER_CODE=000 CURL_EXIT=60 run_tc offsite-repo "$TMP/off"
[ "$RC" = 1 ] && quiet && grep -F 'curl exit 60: its certificate was not trusted' "$TMP/err" >/dev/null \
  && ok "an untrusted certificate is told apart from an unreachable forge" \
  || bad "an untrusted certificate is told apart from an unreachable forge" "rc=$RC $(both | tail -3)"
reset_store; KT_FAIL=create-secret run_tc offsite-repo "$TMP/off"
[ "$RC" = 1 ] && ! grep '^POST' "$TMP/curl.log" >/dev/null && ok "no repository is created when the marker cannot be written" \
  || bad "no repository is created when the marker cannot be written" "rc=$RC $(cat "$TMP/curl.log") $(both | tail -3)"
reset_store; VM=ed-gone run_tc offsite-repo "$TMP/off"
[ "$RC" = 2 ] && [ ! -s "$TMP/curl.log" ] && ok "offsite-repo refuses, and calls nothing, when the VM does not exist" \
  || bad "offsite-repo refuses, and calls nothing, when the VM does not exist" "rc=$RC $(cat "$TMP/curl.log")"

# ---------------------------------------------------------------------------
# 3. destroy and sweep
reset_store; run_tc offsite-repo "$TMP/off"; : > "$TMP/curl.log"; : > "$TMP/log"
run_tc destroy
[ "$RC" = 0 ] && grep -F "DELETE https://${FORGE_HOST}/api/v1/repos/ed-offsite/ed-run " "$TMP/curl.log" >/dev/null && grep '^RESULT:   PASS' "$TMP/out" >/dev/null \
  && ! has_secret ed-run-offsite && quiet \
  && ok "destroy deletes the VM's off-site repository and its marker, and names no host" \
  || bad "destroy deletes the VM's off-site repository and its marker, and names no host" "rc=$RC $(cat "$TMP/curl.log") $(both | tail -4)"
has_secret p09-offsite && ok "destroy leaves the settings Secret alone" || bad "destroy leaves the settings Secret alone" "$(ls -A "$TMP/store/secrets")"
reset_store; run_tc destroy
[ "$RC" = 0 ] && [ ! -s "$TMP/curl.log" ] && ! grep -F 'get secret p09-offsite' "$TMP/log" >/dev/null \
  && ok "a VM with no marker causes no call to the forge and no read of the settings" \
  || bad "a VM with no marker causes no call to the forge and no read of the settings" "rc=$RC $(cat "$TMP/curl.log") $(grep p09-offsite "$TMP/log")"
reset_store; run_tc offsite-repo "$TMP/off"; CURL_DELETE_CODE=404 run_tc destroy
[ "$RC" = 0 ] && grep -F 'was already gone' "$TMP/err" >/dev/null && ok "a repository that is already gone is a clean teardown" \
  || bad "a repository that is already gone is a clean teardown" "rc=$RC $(both | tail -4)"
reset_store; run_tc offsite-repo "$TMP/off"; CURL_DELETE_CODE=500 run_tc destroy
[ "$RC" = 1 ] && grep -F 'off-site repository ed-offsite/ed-run NOT deleted' "$TMP/err" >/dev/null && grep -F "RESULT:   FAIL ... ed-run's off-site repository was not deleted" "$TMP/err" >/dev/null \
  && ok "a repository that could not be deleted fails the teardown and is named" \
  || bad "a repository that could not be deleted fails the teardown and is named" "rc=$RC $(both | tail -4)"
reset_store; run_tc offsite-repo "$TMP/off"; KT_FAIL=get-p09-offsite run_tc destroy
[ "$RC" = 1 ] && grep -F 'NOT deleted: the settings could not be read' "$TMP/err" >/dev/null \
  && ok "settings that cannot be read at teardown fail it: the repository is still there" \
  || bad "settings that cannot be read at teardown fail it: the repository is still there" "rc=$RC $(both | tail -4)"
reset_store; run_tc offsite-repo "$TMP/off"; printf 'someone/else' > "$TMP/store/secrets/ed-run-offsite/repo"; : > "$TMP/curl.log"; run_tc destroy
[ "$RC" = 1 ] && [ ! -s "$TMP/curl.log" ] && ok "a marker that names another repository deletes nothing and fails the teardown" \
  || bad "a marker that names another repository deletes nothing and fails the teardown" "rc=$RC $(cat "$TMP/curl.log")"
reset_store
{ printf 'ed-old %s <none>\n' "$OLD"; printf 'ed-kept %s %s\n' "$OLD" "$((now + 3600))"; } > "$TMP/store/vms"
VM=ed-old run_tc offsite-repo "$TMP/off1"; VM=ed-kept run_tc offsite-repo "$TMP/off2"; : > "$TMP/curl.log"
run_tc sweep ed- 120
grep -F "DELETE https://${FORGE_HOST}/api/v1/repos/ed-offsite/ed-old " "$TMP/curl.log" >/dev/null && ok "sweep deletes the repository of a VM it destroys" \
  || bad "sweep deletes the repository of a VM it destroys" "$(cat "$TMP/curl.log") $(both | tail -4)"
! grep -F 'ed-kept' "$TMP/curl.log" >/dev/null && has_secret ed-kept-offsite && ok "sweep leaves the repository of a kept VM alone" \
  || bad "sweep leaves the repository of a kept VM alone" "$(cat "$TMP/curl.log")"

# ---------------------------------------------------------------------------
# 4. the block edit and the scrub, on install.md's own block
# shellcheck source=/dev/null
. "$LIB"
BLOCK="$(cd "$TREE" && bash "${HERE}/lib/extract-block.sh" --file docs/deployment/install.md --section '# Install Tockmox' --lang bash \
          --containing 'tockmox-recovery-kit.tar.age" --age-recipient' 2>/dev/null)"
E="$(printf '%s\n' "$BLOCK" | offsite_block ca)"; ERC=$?
want='  --offsite-git "$OFFSITE_GIT_URL" --offsite-git-credentials "$OFFSITE_GIT_CREDENTIALS" --offsite-git-ca "$OFFSITE_GIT_CA" \'
[ "$ERC" = 0 ] && [ "$(printf '%s\n' "$E" | grep -B1 -x -e '  --dry-run' | head -1)" = "$want" ] \
  && ok "the destination and its CA go on their own line before --dry-run, by variable name" \
  || bad "the destination and its CA go on their own line before --dry-run, by variable name" "rc=$ERC $(printf '%s\n' "$E" | tail -4)"
[ "$(printf '%s\n' "$E" | grep -v -F -e '--offsite-git')" = "$BLOCK" ] && ok "nothing else in the page's block changes" || bad "nothing else in the page's block changes" "$(diff <(printf '%s\n' "$BLOCK") <(printf '%s\n' "$E") | head -5)"
printf '%s\n' "$E" | bash -n 2>/dev/null && ok "the edited block is still one shell command" || bad "the edited block is still one shell command" "$(printf '%s\n' "$E" | bash -n 2>&1 | head -2)"
E2="$(printf '%s\n' "$BLOCK" | offsite_block)"
printf '%s\n' "$E2" | grep -F -e '--offsite-git-credentials "$OFFSITE_GIT_CREDENTIALS" \' >/dev/null && ! printf '%s\n' "$E2" | grep -F -e '--offsite-git-ca' >/dev/null \
  && ok "without a CA the block gets no --offsite-git-ca" || bad "without a CA the block gets no --offsite-git-ca" "$(printf '%s\n' "$E2" | tail -4)"
printf 'a \\\n  b\n' | offsite_block >/dev/null 2>&1 && bad "a block with no --dry-run line is refused, not passed through" "" || ok "a block with no --dry-run line is refused, not passed through"
S="$(printf 'copy to https://%s/ed-offsite/ed-run.git and HTTPS://%s:8443\n' "$FORGE_HOST" "$(printf '%s' "$FORGE_HOST" | tr '[:lower:]' '[:upper:]')" | TOCKMOX_P09_OFFSITE_SCRUB="$FORGE_HOST" offsite_scrub)"
[ "$S" = 'copy to https://<off-site host>/ed-offsite/ed-run.git and HTTPS://<off-site host>:8443' ] \
  && ok "the scrub replaces the host wherever it appears, in either case" || bad "the scrub replaces the host wherever it appears, in either case" "$S"
[ "$(printf 'a.b\n' | TOCKMOX_P09_OFFSITE_SCRUB='' offsite_scrub)" = 'a.b' ] && [ "$(printf 'forgeXexample\n' | TOCKMOX_P09_OFFSITE_SCRUB='forge.example' offsite_scrub)" = 'forgeXexample' ] \
  && ok "the scrub changes nothing when unset, and a dot in the host matches only a dot" || bad "the scrub changes nothing when unset, and a dot in the host matches only a dot" ""
# P09 uses both (a line-level read: P09 itself needs a cluster).
grep -F 'offsite_scrub < "${STATE}/${name}.out"' "$P09" >/dev/null && grep -F '| offsite_block "${OFFSITE_GIT_CA:+ca}"' "$P09" >/dev/null \
  && ok "P09 scrubs every transcript it prints and edits its bootstrap-forge block with offsite_block" \
  || bad "P09 scrubs every transcript it prints and edits its bootstrap-forge block with offsite_block" "not found in $P09"

# ---------------------------------------------------------------------------
# 5. the lane. It runs unmodified in a copy of the tree's shape, beside stubs of what it calls.
L="$TMP/tree/tests/executed-docs"
mkdir -p "$L/provision" "$TMP/tree/install" "$TMP/lbin"
cp "$LANE_SH" "$L/p09-lane.sh"
cat > "$L/provision/throwaway-cluster.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s KUBECONFIG=%s\n' "$*" "${KUBECONFIG-unset}" >> "$LANE_LOG"
case "$1" in
  create) echo apiVersion: v1 > "$LANE_TMP/guest.kubeconfig"; echo "$LANE_TMP/guest.kubeconfig" ;;
  offsite-check) [ "${STUB_CHECK_RC:-0}" = 0 ] || exit "$STUB_CHECK_RC"; echo "${STUB_CA:-ca}" ;;
  offsite-repo) [ "${STUB_REPO_RC:-0}" = 0 ] || exit "$STUB_REPO_RC"
    mkdir -p "$2"; echo "https://forge.example.internal/ed-offsite/ed-lane.git" > "$2/git-url"; echo forge.example.internal > "$2/host"
    printf 'stub-bot\nstub-token\n' > "$2/git-credentials"; [ "${STUB_CA:-ca}" != ca ] || echo PEM > "$2/ca.crt"; echo "$2" ;;
  offsite-reach) exit "${STUB_REACH_RC:-0}" ;;
esac
STUB
printf '#!/usr/bin/env bash\n[ "$1" = url ] && echo "http://site-repo.stub/tockmox.git"\nexit 0\n' > "$L/provision/site-repo-server.sh"
cat > "$L/run.sh" <<'STUB'
#!/usr/bin/env bash
# a real run.sh leaves a PASS receipt for a path that passed; the lane reads it (p09-lane.sh, lane_receipt)
rcpt() {
  local n f
  n="$(ls "$TOCKMOX_WORKDIR" | grep -c '^receipts-')"
  mkdir -p "$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))"
  case "$1" in P09) f=P09-install-md-end-to-end ;; P11) f=P11-fresh-install-recovery ;; *) return 0 ;; esac
  echo PASS > "$TOCKMOX_WORKDIR/receipts-$(printf %05d $((n+1)))/$f"
}
printf 'run.sh %s url=%s creds=%s ca=%s scrub=%s\n' "$*" "${TOCKMOX_P09_OFFSITE_GIT_URL-unset}" "${TOCKMOX_P09_OFFSITE_GIT_CREDENTIALS-unset}" \
  "${TOCKMOX_P09_OFFSITE_GIT_CA-unset}" "${TOCKMOX_P09_OFFSITE_SCRUB-unset}" >> "$LANE_LOG"
[ "$1" != P09 ] || [ ! -f "${TOCKMOX_P09_OFFSITE_GIT_CREDENTIALS:-/nonexistent}" ] || echo "P09 read the credentials file" >> "$LANE_LOG"
if [ "$1" != P09 ] || [ "${STUB_P09_RC:-0}" = 0 ]; then rcpt "$1"; fi
[ "$1" != P09 ] || exit "${STUB_P09_RC:-0}"
exit 0
STUB
for t in helm kubeseal openssl zsh curl age age-keygen; do printf '#!/bin/sh\nexit 0\n' > "$TMP/lbin/$t"; done
cat > "$TMP/lbin/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"config current-context"*) echo stub-guest ;;
  *"get nodes"*) echo node.stub.invalid ;;
  *"patch configmap argocd-tls-certs-cm"*) echo "kubectl $*" >> "$LANE_LOG"
    for a in "$@"; do f="$a"; done; cp "$f" "$LANE_TMP/patch.json"; exit "${STUB_PATCH_RC:-0}" ;;
esac
STUB
chmod +x "$TMP/lbin"/*
LN=0
run_lane() {  # VAR=value... -> output in $TMP/lout, status in $RC; the tree's bootstrap-forge has the flag unless NOFLAG=1
  LN=$((LN+1)); LH="$TMP/lane-$LN"; mkdir -p "$LH/home" "$LH/work"; : > "$LH/log"
  if [ "${NOFLAG:-0}" = 1 ]; then echo '    --offsite-git) shift 2 ;;' > "$TMP/tree/install/bootstrap-forge.sh"
  else printf '    --offsite-git) shift 2 ;;\n    --offsite-git-ca) shift 2 ;;\n' > "$TMP/tree/install/bootstrap-forge.sh"; fi
  env "$@" HOME="$LH/home" TOCKMOX_WORKDIR="$LH/work" LANE_LOG="$LH/log" LANE_TMP="$LH" PATH="$TMP/lbin:$PATH" \
    KUBECONFIG="$LH/substrate.kubeconfig" TOCKMOX_DOCS_REF=stub TOCKMOX_SUBSTRATE_CONTEXT=stub-substrate \
    TOCKMOX_TEST_NAMESPACE=tockmox-test TOCKMOX_TEST_VM=ed-lane \
    bash "$L/p09-lane.sh" > "$TMP/lout" 2>&1
  RC=$?
}
line() { grep -n -m1 -e "$1" "$LH/log" | cut -d: -f1; }
OD() { printf '%s' "$LH/work/p09-lane/offsite"; }

run_lane
[ "$RC" = 0 ] && ! grep '^offsite-' "$LH/log" >/dev/null && grep -F 'run.sh P09 url=unset creds=unset ca=unset scrub=unset' "$LH/log" >/dev/null \
  && ok "with no off-site copy asked for, the lane calls nothing new and P09 gets no destination" \
  || bad "with no off-site copy asked for, the lane calls nothing new and P09 gets no destination" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git
[ "$RC" = 0 ] && [ "$(line '^offsite-check')" -lt "$(line '^create')" ] && [ "$(line '^create')" -lt "$(line '^offsite-repo')" ] && [ "$(line '^offsite-repo')" -lt "$(line '^offsite-reach')" ] \
  && ok "the settings are checked before the VM is created; the repository and the reach check come after" \
  || bad "the settings are checked before the VM is created; the repository and the reach check come after" "rc=$RC $(cat "$LH/log") $(tail -3 "$TMP/lout")"
grep -F "offsite-repo $(OD) KUBECONFIG=$LH/substrate.kubeconfig" "$LH/log" >/dev/null && grep -F "offsite-reach $(OD) KUBECONFIG=$LH/substrate.kubeconfig" "$LH/log" >/dev/null \
  && ok "both run with the hypervisor's credential" || bad "both run with the hypervisor's credential" "$(cat "$LH/log")"
grep -F "run.sh P09 url=https://forge.example.internal/ed-offsite/ed-lane.git creds=$(OD)/git-credentials ca=$(OD)/ca.crt scrub=forge.example.internal" "$LH/log" >/dev/null \
  && grep -F 'P09 read the credentials file' "$LH/log" >/dev/null \
  && ok "P09 gets the repository, the credentials file, the CA and the host to scrub" \
  || bad "P09 gets the repository, the credentials file, the CA and the host to scrub" "$(grep run.sh "$LH/log")"
grep -F 'run.sh P04 P05 url=unset' "$LH/log" >/dev/null && ok "P04 and P05 get no destination" || bad "P04 and P05 get no destination" "$(grep run.sh "$LH/log")"
[ "$(line 'run.sh P04 P05')" -lt "$(line 'patch configmap argocd-tls-certs-cm')" ] && [ "$(line 'patch configmap argocd-tls-certs-cm')" -lt "$(line 'run.sh P09')" ] \
  && grep -F -e '--context=stub-guest -n argocd patch configmap argocd-tls-certs-cm --type merge' "$LH/log" >/dev/null \
  && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["forge.example.internal"].strip())' "$LH/patch.json" 2>/dev/null)" = PEM ] \
  && ok "the CA goes into the throwaway's argocd-tls-certs-cm under the forge's host, after ArgoCD exists and before P09" \
  || bad "the CA goes into the throwaway's argocd-tls-certs-cm under the forge's host, after ArgoCD exists and before P09" "$(cat "$LH/log") $(cat "$LH/patch.json" 2>&1)"
[ ! -e "$(OD)" ] && ok "the directory holding the token is gone when the lane ends" || bad "the directory holding the token is gone when the lane ends" "$(ls "$(OD)")"
! grep -F -e forge.example.internal -e stub-token "$TMP/lout" >/dev/null && ok "the lane's own output names neither the forge nor the token" \
  || bad "the lane's own output names neither the forge nor the token" "$(grep -F -e forge.example.internal -e stub-token "$TMP/lout")"
run_lane TOCKMOX_P09_OFFSITE=git STUB_CA=no-ca
[ "$RC" = 0 ] && grep -F 'ca=unset scrub=forge.example.internal' "$LH/log" >/dev/null && ! grep -F 'patch configmap' "$LH/log" >/dev/null \
  && ok "a forge on a public CA gets no --offsite-git-ca and no ArgoCD trust entry" || bad "a forge on a public CA gets no --offsite-git-ca and no ArgoCD trust entry" "rc=$RC $(cat "$LH/log")"
NOFLAG=1 run_lane TOCKMOX_P09_OFFSITE=git
[ "$RC" = 2 ] && ! grep '^create' "$LH/log" >/dev/null && grep -F 'has no --offsite-git-ca' "$TMP/lout" >/dev/null \
  && ok "a private CA and a bootstrap-forge without --offsite-git-ca is refused before a VM exists" \
  || bad "a private CA and a bootstrap-forge without --offsite-git-ca is refused before a VM exists" "rc=$RC $(cat "$LH/log") $(tail -2 "$TMP/lout")"
NOFLAG=1 run_lane TOCKMOX_P09_OFFSITE=git STUB_CA=no-ca
[ "$RC" = 0 ] && ok "a public CA needs no --offsite-git-ca, so that tree runs" || bad "a public CA needs no --offsite-git-ca, so that tree runs" "rc=$RC $(tail -2 "$TMP/lout")"
run_lane TOCKMOX_P09_OFFSITE=git STUB_CHECK_RC=2
[ "$RC" = 2 ] && ! grep '^create' "$LH/log" >/dev/null && grep -F 'the off-site settings cannot be read or used' "$LH"/work/report-p09-lane-*.txt >/dev/null 2>&1 \
  && ok "settings that cannot be read stop the run before a VM exists, and the report says why" \
  || bad "settings that cannot be read stop the run before a VM exists, and the report says why" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git TOCKMOX_P09_ROUTE=external
[ "$RC" = 2 ] && ! grep -e '^create' -e '^offsite-' "$LH/log" >/dev/null && ok "an off-site copy on your own forge's route is refused: that route never runs bootstrap-forge" \
  || bad "an off-site copy on your own forge's route is refused: that route never runs bootstrap-forge" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=s3
[ "$RC" = 2 ] && grep -F 'TOCKMOX_P09_OFFSITE must be none or git' "$TMP/lout" >/dev/null && ok "a value other than none or git is refused" || bad "a value other than none or git is refused" "rc=$RC"
run_lane TOCKMOX_P09_OFFSITE=git STUB_REPO_RC=1
[ "$RC" = 1 ] && grep '^destroy' "$LH/log" >/dev/null && ! grep -F 'run.sh' "$LH/log" >/dev/null \
  && ok "a repository that cannot be created stops the lane, and the VM is destroyed" || bad "a repository that cannot be created stops the lane, and the VM is destroyed" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git STUB_REACH_RC=1
[ "$RC" = 1 ] && ! grep -F 'run.sh' "$LH/log" >/dev/null && [ ! -e "$(OD)" ] \
  && ok "a guest that does not reach the forge stops the lane before the install, and the token is not left" \
  || bad "a guest that does not reach the forge stops the lane before the install, and the token is not left" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git STUB_REACH_RC=3
[ "$RC" = 0 ] && grep -F 'run.sh P09 url=https://' "$LH/log" >/dev/null && grep -F 'was not checked' "$TMP/lout" >/dev/null \
  && ok "a reach check that could not run on the guest is said so, and the install goes on to show it" \
  || bad "a reach check that could not run on the guest is said so, and the install goes on to show it" "rc=$RC $(tail -3 "$TMP/lout")"
run_lane TOCKMOX_P09_OFFSITE=git TOCKMOX_KEEP_CLUSTER=1 STUB_REPO_RC=1
[ "$RC" = 1 ] && grep '^destroy' "$LH/log" >/dev/null && grep -F 'no install to keep' "$TMP/lout" >/dev/null \
  && ok "a kept run that stops before P09 began is destroyed: there is no install to keep" \
  || bad "a kept run that stops before P09 began is destroyed: there is no install to keep" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git TOCKMOX_KEEP_CLUSTER=1 STUB_REPO_RC=1 TOCKMOX_KEEP_ON_PREP_FAILURE=1
[ "$RC" = 1 ] && ! grep '^destroy' "$LH/log" >/dev/null \
  && ok "TOCKMOX_KEEP_ON_PREP_FAILURE=1 keeps it anyway" || bad "TOCKMOX_KEEP_ON_PREP_FAILURE=1 keeps it anyway" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git TOCKMOX_KEEP_CLUSTER=1 STUB_P09_RC=1
[ "$RC" = 1 ] && ! grep '^destroy' "$LH/log" >/dev/null \
  && ok "a kept run whose P09 failed stays up: that install is what keep is for" || bad "a kept run whose P09 failed stays up: that install is what keep is for" "rc=$RC $(cat "$LH/log")"
run_lane TOCKMOX_P09_OFFSITE=git STUB_PATCH_RC=1
[ "$RC" = 1 ] && ! grep -F 'run.sh P09' "$LH/log" >/dev/null && ok "a CA that cannot be added to ArgoCD's trust stops the lane before P09" \
  || bad "a CA that cannot be added to ArgoCD's trust stops the lane before P09" "rc=$RC $(cat "$LH/log")"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

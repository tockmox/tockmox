#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Hermetic proof of P16's rows: move-in-forge moves a running site into the built-in forge, every Application reads
# it, Synced and Healthy, nothing is pruned, the migration commit is the only new commit, the old repository is the
# off-site copy with its history, and a dirty checkout is refused before any write. No cluster. Four layers.
#
#   1. The verdicts (lib/p16-move-in-forge.py). A green fixture for each, then one planted red per thing the verdict
#      reads, each of which must change the verdict. An empty or unreadable input is never a pass.
#   2. The page and the installer. The block P16 runs resolves in this tree to one block, holds the three placeholders
#      P16 fills once each and one --dry-run, and the page's two success conditions are the words the installer
#      prints; the names P16 reads (the in-cluster address, the credential copy, the migration commit's author, the
#      refusal and the prompt) are the installer's; and the reason P16 refuses a private CA still holds.
#   3. The path as a script, against a stub product: git is real (P09's site repository, the git daemon, the external
#      forge and the built-in forge are bare repositories reached through insteadOf), kubectl answers from one state
#      file that the path's own calls change, and a stand-in tockmox-install.sh does what move-in-forge does to that
#      state and those repositories. Green end to end, then one broken product per row, each of which must fail the
#      path at that row while the stand-in still prints the success line. Then mutated copies of P16 that lose a step
#      or a guard, each of which must not end PASS.
#   4. The gate: P16 runs after P09 on the external route with an external forge to move from, and must declare
#      BLOCKED, with no cluster call, when any of them is missing, or when that forge is on a private CA.
#
#   ./tests/executed-docs/move-in-rows-test.sh
#   P16=/path/to/P16.sh ./tests/executed-docs/move-in-rows-test.sh     another copy, to show it goes red there
# shellcheck disable=SC2015  # `test && ok || bad`: ok only prints and counts, so it cannot fail into bad
# shellcheck disable=SC2016  # fixture text is literal
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "${HERE}/../.." && pwd)"
P16="${P16:-${HERE}/paths/P16-move-in-forge.sh}"
PY="${HERE}/lib/p16-move-in-forge.py"
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
isun() { # LABEL ACTUAL ... the verdict must be unreadable
  case "$2" in unreadable*) ok "$1" ;; *) bad "$1" "expected unreadable, got [${2}]" ;; esac
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
export GIT_CONFIG_NOSYSTEM=1
FROM_URL="https://forge.stub.invalid/ed-org/ed-vm.git"
FROM_SSH="git@forge.stub.invalid:ed-org/ed-vm"
OLD_URL="git://node.stub.invalid:31234/site.git"
FORGE_SVC=tockmox-forge-http; FORGE_NS=tockmox-forge
IN_URL="http://${FORGE_SVC}.${FORGE_NS}.svc.cluster.local:3000/tockmox/site.git"
PRODUCT_URL="git://site-repo.stub.invalid/tockmox.git"

# ------------------------------------------------------------------ 1. the verdicts
A="${TMP}/apps.json"
# mk_apps FILE ROOT-URL AI-URL [AI-SYNC] [AI-HEALTH] [AI-RES-COUNT] [ROOT-REV]
mk_apps() {
  python3 - "$@" <<'PY'
import json, sys
f, root, ai = sys.argv[1], sys.argv[2], sys.argv[3]
sync = sys.argv[4] if len(sys.argv) > 4 else "Synced"
health = sys.argv[5] if len(sys.argv) > 5 else "Healthy"
n = int(sys.argv[6]) if len(sys.argv) > 6 else 2
rev = sys.argv[7] if len(sys.argv) > 7 else "abc"
def app(name, srcs, res, s="Synced", h="Healthy", r=""):
    return {"metadata": {"name": name}, "spec": {"sources": [{"repoURL": u} for u in srcs]},
            "status": {"sync": {"status": s, "revision": r}, "health": {"status": h},
                       "resources": [{"group": g, "kind": k, "namespace": "ns", "name": x} for g, k, x in res]}}
res = [("apps", "Deployment", "a"), ("", "Service", "b"), ("", "ConfigMap", "c")][:n]
json.dump({"kind": "List", "items": [
    app("tockmox-root", [root], [("argoproj.io", "Application", "tockmox-ai")], r=rev),
    app("tockmox-ai", ["https://github.com/tockmox/tockmox.git", ai], res, sync, health),
    app("charts", ["https://github.com/tockmox/tockmox.git"], [("", "ConfigMap", "x")])]}, open(f, "w"))
PY
}
mk_apps "$A" "$FROM_URL" "$FROM_URL"
is "root: the root reads the external repository" "the external repository" "$(v root --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$A" "$FROM_SSH" "$FROM_URL"
is "root: the ssh spelling of the same repository is the same repository" "the external repository" "$(v root --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$A" "$IN_URL" "$IN_URL"
is "root: the root reads the built-in forge" "the built-in forge" "$(v root --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$A" "https://elsewhere.invalid/x/y.git" "$IN_URL"
is "root: another repository is named, not taken for either" "another repository: elsewhere.invalid/x/y" "$(v root --from "$FROM_URL" --in "$IN_URL" < "$A")"
is "root: no root Application reads absent" "absent" "$(v root --root nope --from "$FROM_URL" --in "$IN_URL" < "$A")"
isun "root: an empty read is unreadable" "$(: | v root --from "$FROM_URL" --in "$IN_URL")"
isun "root: an API error object is unreadable" "$(printf '{"kind":"Status","code":503}' | v root --from "$FROM_URL" --in "$IN_URL")"
mk_apps "$A" "$IN_URL" "$IN_URL" Synced Healthy 2 deadbeef
is "revision: the root's synced revision" "deadbeef" "$(v revision < "$A")"
mk_apps "$A" "$IN_URL" "$IN_URL" Synced Healthy 2 ""
isun "revision: a root with no revision is unreadable" "$(v revision < "$A")"
mk_apps "$A" "$FROM_URL" "$FROM_URL"
is "settled: every Application Synced and Healthy" "3 Synced and Healthy" "$(v settled < "$A")"
mk_apps "$A" "$FROM_URL" "$FROM_URL" OutOfSync
is "settled: one OutOfSync is named" "not settled: tockmox-ai is OutOfSync/Healthy" "$(v settled < "$A")"
mk_apps "$A" "$FROM_URL" "$FROM_URL" Synced Degraded
is "settled: one Degraded is named" "not settled: tockmox-ai is Synced/Degraded" "$(v settled < "$A")"
isun "settled: no Application at all is unreadable" "$(printf '{"items":[]}' | v settled)"
mk_apps "$A" "$FROM_URL" "$FROM_URL"
is "reads: two Applications read the external repository" "2 read it" "$(v reads --url "$FROM_URL" < "$A")"
is "reads: none reads another" "0 read it" "$(v reads --url "$OLD_URL" < "$A")"
B="${TMP}/before.json"; mk_apps "$B" "$FROM_URL" "$FROM_URL"
mk_apps "$A" "$IN_URL" "$IN_URL"
is "moved: both that read it read the forge" "every Application that read the external repository reads the built-in forge (2)" "$(v moved --before "$B" --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$A" "$IN_URL" "$FROM_URL"
is "moved: one left on the external repository is named" "not moved: tockmox-ai still reads the external repository" "$(v moved --before "$B" --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$A" "$IN_URL" "https://elsewhere.invalid/x/y.git"
is "moved: one that reads neither is named" "not moved: tockmox-ai reads neither" "$(v moved --before "$B" --from "$FROM_URL" --in "$IN_URL" < "$A")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["items"]=[a for a in d["items"] if a["metadata"]["name"]!="tockmox-ai"]; json.dump(d,open(sys.argv[1],"w"))' "$A"
is "moved: one that is gone is named" "not moved: tockmox-ai is gone" "$(v moved --before "$B" --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$B" "$IN_URL" "$IN_URL"; mk_apps "$A" "$IN_URL" "$IN_URL"
isun "moved: a list before that read nothing from the external repository is unreadable (a move of nothing proves nothing)" "$(v moved --before "$B" --from "$FROM_URL" --in "$IN_URL" < "$A")"
isun "moved: a missing list before is unreadable" "$(v moved --before "${TMP}/none.json" --from "$FROM_URL" --in "$IN_URL" < "$A")"
mk_apps "$B" "$FROM_URL" "$FROM_URL" Synced Healthy 3; mk_apps "$A" "$IN_URL" "$IN_URL" Synced Healthy 3
is "pruned: every resource still managed" "nothing pruned (5 resources)" "$(v pruned --before "$B" < "$A")"
mk_apps "$A" "$IN_URL" "$IN_URL" Synced Healthy 2
is "pruned: one resource gone is named" "pruned: tockmox-ai lost 1, e.g. ConfigMap/ns/c" "$(v pruned --before "$B" < "$A")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["items"]=[a for a in d["items"] if a["metadata"]["name"]!="charts"]; json.dump(d,open(sys.argv[1],"w"))' "$A"
case "$(v pruned --before "$B" < "$A")" in "pruned: charts lost 1"*) ok "pruned: an Application that is gone lost everything it managed" ;; *) bad "pruned: gone app" "$(v pruned --before "$B" < "$A")" ;; esac
isun "pruned: an empty read is unreadable" "$(: | v pruned --before "$B")"
printf '{"items":[{"metadata":{"name":"a"},"spec":{},"status":{}}]}' > "$B"
isun "pruned: nothing managed before is unreadable, never 'nothing pruned'" "$(printf '{"items":[]}' | v pruned --before "$B")"
SEC="$(printf '{"data":{"url":"%s"}}' "$(printf '%s' "$FROM_SSH" | base64 | tr -d '\n')")"
is "credential: a Secret naming the repository in its ssh spelling names it" "names the URL's repository" "$(printf '%s' "$SEC" | v credential --url "$FROM_URL")"
is "credential: a Secret naming the forge names another repository" "names another repository" "$(printf '{"data":{"url":"%s"}}' "$(printf '%s' "$IN_URL" | base64 | tr -d '\n')" | v credential --url "$FROM_URL")"
isun "credential: no Secret is unreadable" "$(: | v credential --url "$FROM_URL")"
RW="${TMP}/rw"; mkdir -p "$RW/a" "$RW/.git"
printf 'spec:\n  source:\n    repoURL: %s   # site\n  sources:\n    - repoURL: "%s"\n    - repoURL: %s\n' "$OLD_URL" "${OLD_URL%.git}" "$PRODUCT_URL" > "$RW/a/x.yaml"
printf 'repoURL: %s\n' "$OLD_URL" > "$RW/.git/config.yaml"; printf 'repoURL: %s\n' "$OLD_URL" > "$RW/a/notes.txt"
is "rewrite: both spellings in YAML are rewritten, nothing under .git and no other file" "rewrote 2 line(s) in 1 file(s)" "$(v rewrite --old "$OLD_URL" --new "$FROM_URL" "$RW")"
is "rewrite: the comment and the quoting are kept, and the product's own repository is left" \
  "    repoURL: ${FROM_URL}   # site|    - repoURL: \"${FROM_URL}\"|    - repoURL: ${PRODUCT_URL}" "$(sed -n '3p;5,6p' "$RW/a/x.yaml" | tr '\n' '|' | sed 's/|$//')"
python3 -I "$PY" rewrite --old "$OLD_URL" --new "$FROM_URL" "$RW" >/dev/null && bad "rewrite: a second run finds nothing and fails" "exit 0" || ok "rewrite: a second run finds nothing to rewrite and exits 1"
printf 'u1\ntok1\n' > "${TMP}/cred"
SJ="$(python3 -I "$PY" argo-secret --name s --url "$FROM_URL" --credentials "${TMP}/cred")"
is "argo-secret: a repository Secret for the URL, with the file's two lines" "repository ${FROM_URL} u1 tok1" \
  "$(printf '%s' "$SJ" | python3 -c 'import json,sys,base64; s=json.load(sys.stdin); d=s["data"]; print(s["metadata"]["labels"]["argocd.argoproj.io/secret-type"], *(base64.b64decode(d[k]).decode() for k in ("url","username","password")))')"
is "scrub: the host is replaced, in any case" "at <external forge>/x and <external forge>" "$(printf 'at forge.stub.invalid/x and FORGE.stub.invalid' | python3 -I "$PY" scrub --host forge.stub.invalid)"

# ------------------------------------------------------------------ 2. the page and the installer
PAGE="${TREE}/docs/administration/site-forge.md"
MI="${TREE}/install/forge-move-in.sh"
BL="${TMP}/block.sh"
# pagehas TEXT ... the page holds TEXT, its line breaks read as spaces
pagehas() { python3 -I -c 'import re,sys; t=re.sub(r"\s+"," ",open(sys.argv[1]).read()); sys.exit(0 if sys.argv[2] in t else 1)' "$PAGE" "$1"; }
bash "$EXTRACT" --file "$PAGE" --section '## Move a running site in' --lang bash --containing 'move-in-forge --context' > "$BL" 2>/dev/null
[ -s "$BL" ] && ok "page: the block P16 runs resolves in this tree, to one block" || bad "page: the block resolves" ""
is "page: it holds each placeholder P16 fills once, and one --dry-run" "1 1 1 1" \
  "$(for p in YOUR_SITE_CHECKOUT YOUR_SITE_REPOSITORY_HTTPS_URL YOUR_AGE_PUBLIC_KEY ' --dry-run'; do grep -o -- "$p" "$BL" | wc -l | tr -d ' '; done | tr '\n' ' ' | sed 's/ $//')"
bash -n "$BL" 2>/dev/null && ok "page: the block parses in bash as well as zsh (an apostrophe inside a \${VAR:?...} guard does not)" || bad "page: the block does not parse in bash" "$(bash -n "$BL" 2>&1 | head -1)"
grep -q -- '--from-credentials "$HOME/tockmox-backup/site-repo-push"' "$BL" && grep -q -- '--sealing-key-backup "$HOME/tockmox-backup/sealed-secrets.key.enc"' "$BL" \
  && ok "page: the push credential and the key export are under \$HOME/tockmox-backup, where P16 writes them" || bad "page: the block's files" "$(cat "$BL")"
pagehas 'Run it again without `--dry-run` to move; it asks you to type the context name.' \
  && ok "page: 'run it again without --dry-run' and the typed context are the page's own words" || bad "page: the dry-run sentence" ""
pagehas '**Success condition:** it ends with `every Application reads the built-in forge, Synced and Healthy, and nothing was pruned`. Run it again: it says `Nothing to do`.' \
  && ok "page: its two success conditions are where P16 reads them" || bad "page: success conditions" ""
grep -qF 'ok "every Application reads the built-in forge, Synced and Healthy, and nothing was pruned"' "$MI" && grep -qF 'Nothing to do."' "$MI" \
  && ok "installer: it prints the page's two success conditions in the words P16 matches" || bad "installer: success lines" ""
grep -qF 'has uncommitted or untracked changes' "$MI" && grep -qF 'Nothing was touched.' "$MI" && grep -qF 'Type the context name to go on: ' "$MI" \
  && grep -qF 'say "Dry run: nothing was changed"' "$MI" && ok "installer: the refusal, the prompt and the dry run's last line are the words P16 matches" || bad "installer: messages" ""
grep -qF 'RELEASE="tockmox-forge"; ORG="tockmox"; REPO="site"' "$MI" && grep -qF 'IN_CLUSTER="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/${ORG}/${REPO}.git"' "$MI" \
  && grep -qF 'FORGE_NS="tockmox-forge"' "$MI" && ok "installer: the in-cluster address P16 expects is the one it writes" || bad "installer: in-cluster address" ""
grep -qF 'CRED_COPY="tockmox-site-repo-before-move"' "$MI" && grep -qF 'user.name="Tockmox installer"' "$MI" && grep -qF 'ROOT_APP="tockmox-root"' "$MI" \
  && ok "installer: the credential copy, the migration commit's author and the root are the names P16 reads" || bad "installer: names" ""
grep -qF -- '--offsite-git|--offsite-git-credentials)' "$MI" && ! grep -qF -- '--offsite-git-ca' "$MI" && grep -qF 'if [[ -n "$OS_GIT_URL$OS_GIT_CREDS$OS_GIT_CA" ]]; then' "${TREE}/install/bootstrap-forge.sh" \
  && ok "installer: P16's reason to refuse a private CA still holds (no CA option of move-in-forge's own, and bootstrap-forge takes --offsite-git-ca only with --offsite-git)" \
  || bad "installer: the CA reason" "move-in-forge or bootstrap-forge changed: re-read P16's ca.crt gate and its INVENTORY row"

# ------------------------------------------------------------------ 3. the path as a script
BIN="${TMP}/bin"; mkdir -p "$BIN"
GT="${TMP}/gt"; mkdir -p "$GT/paths" "$GT/tockmox/install"; ln -s "${HERE}/lib" "$GT/lib"
cat > "$BIN/state.py" <<'STATEPY'
#!/usr/bin/env python3
# Argo CD and the cluster, stood in for, from one state file. argv[1] is the tool: kubectl, or move-in for the
# stand-in installer's changes. SB_MODE breaks one thing.
import base64, json, os, re, subprocess, sys
SB = os.environ["SB"]; MODE = os.environ.get("SB_MODE", "")
SF = os.path.join(SB, "state.json")
FROM, OLD, IN = os.environ["SB_FROM"], os.environ["SB_OLD"], os.environ["SB_IN"]
URL = re.compile(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$')
def norm(u):
    m = URL.match(u.strip().strip('"')); return (m.group(1).lower() + "/" + m.group(2)) if m else u
def bare(u):
    return {norm(FROM): "from.git", norm(OLD): "old.git", norm(IN): "forge.git"}.get(norm(u))
def head(u):
    b = bare(u)
    return subprocess.run(["git", "--git-dir", os.path.join(SB, b), "rev-parse", "main"], capture_output=True, text=True).stdout.strip() if b else ""
st = json.load(open(SF))
def save(): json.dump(st, open(SF, "w"))
def point(url):  # every Application's site source names url; the root is synced to its main
    for n, a in st["apps"].items():
        if a.get("site"):
            a["src"][-1] = url
    st["apps"]["tockmox-root"]["rev"] = head(url)
def kubectl(a):
    j = " ".join(a)
    if "port-forward" in j:
        os.execvp("sleep", ["sleep", "600"])
    if "get applications.argoproj.io" in j:
        items = []
        for n, x in st["apps"].items():
            items.append({"metadata": {"name": n}, "spec": {"sources": [{"repoURL": u} for u in x["src"]]},
                          "status": {"sync": {"status": x.get("sync", "Synced"), "revision": x.get("rev", "")},
                                     "health": {"status": x.get("health", "Healthy")},
                                     "resources": [{"group": "", "kind": k, "namespace": "ns", "name": r} for k, r in x["res"]]}})
        print(json.dumps({"kind": "List", "items": items})); return 0
    if a[-3:-1] == ["apply", "-f"] and a[-1] == "-":
        s = json.loads(sys.stdin.read())
        st["secrets"][s["metadata"]["name"]] = base64.b64decode(s["data"]["url"]).decode(); save(); print("secret configured"); return 0
    if a[-3:-1] == ["apply", "-f"]:
        m = re.search(r'repoURL:\s*"?([^\s"#]+)', open(a[-1]).read())
        point(m.group(1))
        if MODE == "stage-unsettled":
            st["apps"]["tockmox-ai"]["sync"] = "OutOfSync"
        save(); print("application configured"); return 0
    if "get namespace tockmox-forge" in j:
        return 0 if "tockmox-forge" in st["ns"] else 1
    m = re.search(r"-n argocd get secret (\S+) -o (name|json)", j)
    if m:
        if m.group(1) not in st["secrets"]: return 1
        print("secret/" + m.group(1) if m.group(2) == "name" else json.dumps({"data": {"url": base64.b64encode(st["secrets"][m.group(1)].encode()).decode()}})); return 0
    if "-n tockmox-forge get secret tockmox-forge-admin" in j:
        if "tockmox-forge" not in st["ns"]: return 1
        print(base64.b64encode(b"tockmox-admin" if "username" in j else b"stubpass").decode(), end=""); return 0
    if "config view --minify" in j:
        print("https://stub.invalid:6443", end=""); return 0
    if "app.kubernetes.io/name=sealed-secrets" in j:
        print("kube-system/sealed-secrets-controller", end=""); return 0
    sys.stderr.write("stub kubectl: no answer for: %s\n" % j); return 1
def move_in(op):
    if op == "write":       # what a refusal or a dry run must never do
        st["ns"].append("tockmox-forge")
    elif op == "moved?":
        print("yes" if norm(st["apps"]["tockmox-root"]["src"][-1]) == norm(IN) else "no"); return 0
    elif op == "cutover":
        st["ns"].append("tockmox-forge"); st["secrets"]["tockmox-site-repo-before-move"] = FROM
        point(IN)
        if MODE == "leaves-one": st["apps"]["tockmox-identity"]["src"][-1] = FROM
        if MODE == "unsettled": st["apps"]["tockmox-ai"]["health"] = "Degraded"
        if MODE == "prunes": st["apps"]["tockmox-ai"]["res"] = st["apps"]["tockmox-ai"]["res"][:1]
        if MODE == "root-unsynced": st["apps"]["tockmox-root"]["rev"] = "0" * 40
        if MODE != "keeps-copy": st["secrets"].pop("tockmox-site-repo-before-move", None)
        st["secrets"]["tockmox-site-repo"] = IN
    save(); return 0
sys.exit(kubectl(sys.argv[2:]) if sys.argv[1] == "kubectl" else move_in(sys.argv[2]))
STATEPY
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${SB}/calls.log"\nexec python3 -I "%s/state.py" kubectl "$@"\n' "$BIN" > "$BIN/kubectl"
cat > "$BIN/age-keygen" <<'STUB'
#!/usr/bin/env bash
# -o FILE writes an identity; -y FILE prints its public key
case "$1" in -o) printf 'AGE-SECRET-KEY-1STUB\n' > "$2" ;; -y) [ -s "$2" ] && echo age1stubrecipient ;; esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$BIN/age"
# The stand-in installer: bootstrap-secrets writes an age file; move-in-forge does to the repositories and the state
# what the real one does (installer tests MI1-MI6 and the lab prove the real one), and prints what it prints.
cat > "$GT/tockmox/install/tockmox-install.sh" <<'INST'
#!/usr/bin/env bash
set -uo pipefail
S() { python3 -I "${SB_BIN}/state.py" move-in "$@"; }
cmd="$1"; shift
if [ "$cmd" = bootstrap-secrets ]; then
  while [ $# -gt 0 ]; do [ "$1" = --backup-out ] && out="$2"; shift; done
  printf 'age-encryption.org/v1\n-> X25519 stub\n' > "$out"; echo "key backup written"; exit 0
fi
[ "$cmd" = move-in-forge ] || { echo "stand-in: $cmd" >&2; exit 2; }
site=""; from=""; dry=0; ctx=""
while [ $# -gt 0 ]; do
  case "$1" in --site) site="$2"; shift ;; --from) from="$2"; shift ;; --context) ctx="$2"; shift ;; --dry-run) dry=1 ;; --) break ;; esac; shift
done
echo "== Checking the request"
[ "${SB_MODE:-}" = asks-first ] && [ "$dry" = 0 ] && printf '    Move the site of %s? Type the context name to go on: \n' "$ctx"
if [ -n "$(git -C "$site" status --porcelain)" ] && [ "${SB_MODE:-}" != no-dirty-refusal ]; then
  [ "${SB_MODE:-}" = writes-before-refusing ] && S write
  echo "  x $site has uncommitted or untracked changes:" >&2; git -C "$site" status --porcelain >&2
  echo "       Commit and push them, or clean them away. Nothing was touched." >&2; exit 1
fi
if [ "$(S moved?)" = yes ] && [ "${SB_MODE:-}" != rerun-not-noop ]; then
  echo "  ok Argo CD already reads the built-in forge and every Application is Synced and Healthy. Nothing to do."; exit 0
fi
w="$(mktemp -d)"; git clone -q --no-local "$site" "$w/t"
for f in $(grep -rlF "$from" "$w/t" --include='*.yaml'); do sed -i "s|${from}|${SB_IN}|g" "$f"; done
if [ "$dry" = 1 ]; then
  [ "${SB_MODE:-}" = dry-run-writes ] && S write
  echo "== Dry run: nothing was changed"; git -C "$w/t" diff --stat | sed 's/^/      /'; rm -rf "$w"; exit 0
fi
[ "${SB_MODE:-}" = asks-first ] || printf '    Move the site of %s? Type the context name to go on: \n' "$ctx"
if [ "${SB_MODE:-}" = two-commits ]; then echo extra > "$w/t/extra.txt"; git -C "$w/t" add -A; git -C "$w/t" -c user.name=x -c user.email=x@x.invalid commit -qm extra; fi
git -C "$w/t" -c user.name="Tockmox installer" -c user.email=installer@tockmox-forge.invalid commit -qam "Move the site repository into the built-in forge"
git -C "$w/t" push -q "${SB}/forge.git" HEAD:refs/heads/main
S cutover
case "${SB_MODE:-}" in
  no-mirror) ;;
  rewrites-history) git -C "$w/t" checkout -q --orphan fresh && git -C "$w/t" -c user.name=x -c user.email=x@x.invalid commit -qm fresh && git -C "$w/t" push -q --force "${SB}/from.git" HEAD:refs/heads/main ;;
  *) git -C "$w/t" push -q --force "${SB}/from.git" HEAD:refs/heads/main ;;
esac
[ "${SB_MODE:-}" = changes-checkout ] && git -C "$site" -c user.name=x -c user.email=x@x.invalid commit -q --allow-empty -m oops
echo "  ok every Application reads the built-in forge, Synced and Healthy, and nothing was pruned"
rm -rf "$w"; exit 0
INST
chmod +x "$BIN"/* "$GT/tockmox/install/tockmox-install.sh"

# sandbox ... P09's state (its PASS marker, its session naming the site repository), the site repository with its
# origin on the git daemon, the daemon's, the external forge's and the built-in forge's repositories, Argo CD reading
# the daemon, and the directory the lane makes for the external forge
sandbox() {
  local d; d="$(mktemp -d "${TMP}/sbx.XXXXXX")"
  mkdir -p "$d/p09" "$d/from-dir"; : > "$d/p09/p09-passed"
  for r in old from forge; do git init -q --bare -b main "$d/$r.git"; done
  printf '[url "%s"]\n\tinsteadOf = %s\n[url "%s"]\n\tinsteadOf = %s\n[url "%s"]\n\tinsteadOf = %s\n[safe]\n\tdirectory = *\n' \
    "$d/old.git" "$OLD_URL" "$d/from.git" "$FROM_URL" "$d/forge.git" "http://127.0.0.1:3016/tockmox/site.git" > "$d/gitconfig"
  local s="$d/site"; git init -q -b main "$s"
  mkdir -p "$s/bootstrap/applications" "$s/site/values"
  printf 'kind: Application\nmetadata:\n  name: tockmox-root\nspec:\n  source:\n    repoURL: %s\n    path: bootstrap/applications\n' "$OLD_URL" > "$s/bootstrap/root.yaml"
  printf 'spec:\n  sources:\n    - repoURL: %s\n    - repoURL: %s\n      ref: values\n' "$PRODUCT_URL" "$OLD_URL" > "$s/bootstrap/applications/tockmox-ai.yaml"
  printf 'spec:\n  source:\n    repoURL: %s\n' "$OLD_URL" > "$s/bootstrap/applications/tockmox-identity.yaml"
  printf 'global:\n  internalDomain: lab.stub.invalid\n' > "$s/site/values/global.yaml"
  git -C "$s" add -A; git -C "$s" -c user.name=p09 -c user.email=p09@x.invalid commit -qm "the generated site"
  printf 'b: 1\n' >> "$s/site/values/global.yaml"; git -C "$s" -c user.name=p09 -c user.email=p09@x.invalid commit -qam "sealed credentials"
  git -C "$s" remote add origin "$OLD_URL"; GIT_CONFIG_GLOBAL="$d/gitconfig" git -C "$s" push -q origin main
  printf 'declare -x SITE_REPO="%s"\n' "$s" > "$d/p09/session.env"
  printf '%s\n' "$FROM_URL" > "$d/from-dir/git-url"; printf 'git\nstub-token-p16\n' > "$d/from-dir/git-credentials"; printf 'forge.stub.invalid\n' > "$d/from-dir/host"
  python3 - "$d/state.json" "$OLD_URL" "$PRODUCT_URL" "$(git -C "$s" rev-parse HEAD)" <<'PY'
import json, sys
f, old, prod, rev = sys.argv[1:5]
json.dump({"ns": ["argocd", "kube-system"], "secrets": {}, "apps": {
  "tockmox-root": {"src": [old], "site": True, "rev": rev, "res": [["Application", "tockmox-ai"], ["Application", "tockmox-identity"]]},
  "tockmox-ai": {"src": [prod, old], "site": True, "res": [["Deployment", "litellm"], ["Service", "litellm"], ["ConfigMap", "values"]]},
  "tockmox-identity": {"src": [old], "site": True, "res": [["Deployment", "authentik"]]},
  "charts": {"src": [prod], "res": [["ConfigMap", "c"]]}}}, open(f, "w"))
PY
  printf '%s' "$d"
}
# run_p16 FILE SANDBOX [VAR=VALUE ...] ... the path as run.sh runs it; prints "rc|receipt"
run_p16() {
  local f="$1" d="$2"; shift 2
  env SB="$d" SB_BIN="$BIN" SB_FROM="$FROM_URL" SB_OLD="$OLD_URL" SB_IN="$IN_URL" GIT_CONFIG_GLOBAL="$d/gitconfig" \
      PATH="${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="$d/r" TOCKMOX_PATH_NAME=P16-move-in-forge KUBE_CONTEXT=stub-ctx \
      TOCKMOX_DOCS_REF=HEAD TOCKMOX_P09_ROUTE=external TOCKMOX_P16_FROM_TREE=1 TOCKMOX_P16_PAGE_FILE="${TREE}/docs/administration/site-forge.md" \
      TOCKMOX_P16_TOCKMOX="$GT/tockmox" TOCKMOX_P16_FROM_DIR="$d/from-dir" TOCKMOX_P16_SHELL=bash TOCKMOX_P16_POLL=0 \
      TOCKMOX_P16_SETTLE=0 TOCKMOX_P09_STATE="$d/p09" "$@" bash "$f" > "$d/out" 2>&1
  local rc=$?
  printf '%s|%s' "$rc" "$(cut -d' ' -f1 "$d/r/P16-move-in-forge" 2>/dev/null)"
}
failed_rows() { awk -F'\t' '$3 != $4 {print $2}' "$1/p09/p16/verdicts.tsv" 2>/dev/null; }

d="$(sandbox)"; r="$(run_p16 "$P16" "$d")"
is "path: green end to end against an honest product: exit 0 and a PASS receipt" "0|PASS" "$r"
[ -z "$(failed_rows "$d")" ] && [ "$(grep -c 'row [12345]:' "$d/p09/p16/verdicts.tsv" 2>/dev/null)" = 13 ] \
  && ok "path: the five rows were recorded ($(grep -c . "$d/p09/p16/verdicts.tsv") verdicts), and none is red" || bad "path: rows" "$(failed_rows "$d" | head -3 | tr '\n' ';'); $(tail -5 "$d/out" | tr '\n' ';' | cut -c1-300)"
[ -s "$d/calls.log" ] && ! grep -v -E -- '--context(=| )stub-ctx' "$d/calls.log" >/dev/null && ok "path: every kubectl call names its cluster ($(grep -c . "$d/calls.log") calls)" || bad "path: every call names its cluster" "$(grep -v -- 'stub-ctx' "$d/calls.log" | head -2)"
! grep -rF 'forge.stub.invalid' "$d/out" "$d/p09/p16/"*.out "$d/p09/p16/"*.block "$d/p09/p16/verdicts.tsv" "$d/p09/p16/notes.txt" >/dev/null 2>&1 \
  && ok "path: the external forge's host is in no log, no block and no verdict" || bad "path: host leaked" "$(grep -rlF 'forge.stub.invalid' "$d/out" "$d/p09/p16/" 2>/dev/null | head -3)"
! grep -rF --exclude-dir=home 'stub-token-p16' "$d/out" "$d/p09/p16" >/dev/null 2>&1 && ! grep -F 'stub-token-p16' "$d/calls.log" >/dev/null && ! grep -F 'stubpass' "$d/out" "$d/calls.log" >/dev/null 2>&1 \
  && ok "path: the external forge's token and the forge admin's password are on no command line and in no log (the token is only in the push-credential file the page names)" || bad "path: a secret leaked" ""
is "path: the move left the external repository as the off-site copy, the forge's main on it" \
  "$(git --git-dir "$d/forge.git" rev-parse main)" "$(git --git-dir "$d/from.git" rev-parse main)"
grep -q 'DOES NOT PROVE' "$d/out" && grep -q 'SUCCESS CONDITIONS STATED' "$d/out" && ok "path: the log says what the run does not prove, and what success conditions the page states" || bad "path: caveats in the log" ""
grep -q 'GLUE: an untracked file' "$d/out" && grep -q 'EDIT AS THE PAGE SAYS' "$d/out" && ok "path: its GLUE and its edit of the page's block are labelled in the log" || bad "path: labels" ""

# one broken product per row: the path must fail, and at that row; the stand-in still says the move succeeded
broken() { # MODE LABEL ROW-TEXT
  local d r; d="$(sandbox)"; r="$(run_p16 "$P16" "$d" SB_MODE="$1")"
  if [ "$r" = "1|PRODUCT_FAIL" ] && failed_rows "$d" | grep -F -- "$3" >/dev/null; then ok "$2"
  else bad "$2" "rc|receipt=[${r}] red rows: $(failed_rows "$d" | cut -c1-80 | tr '\n' ';')"; fi
}
broken leaves-one "red: a move that leaves one Application on the external repository fails row 1" "row 1: every Application that read the external repository reads the built-in forge"
broken root-unsynced "red: a root that is not synced to the forge's main fails row 1" "row 1: the root is synced to the forge's main"
broken unsettled "red: an Application left Degraded fails row 1's Synced and Healthy" "row 1: every Application is Synced and Healthy after the move"
broken prunes "red: a move that prunes a resource fails row 2" "row 2: nothing any Application managed"
broken two-commits "red: a move that adds a second commit fails row 3" "row 3: the forge's main is ONE commit"
broken no-mirror "red: an external repository left behind the forge fails row 4's off-site copy" "row 4: the external repository is the off-site copy"
broken rewrites-history "red: an external repository whose history was rewritten fails row 4's pre-move history" "row 4: the external repository still holds the pre-move history"
broken no-dirty-refusal "red: a move that goes ahead on a dirty checkout fails row 5" "row 5: the move refuses a dirty checkout"
broken writes-before-refusing "red: a refusal that writes first fails row 5's nothing written" "row 5: nothing was written"
broken asks-first "red: a refusal that asks for the context first fails row 5's order" "row 5: it refused before it asked for the context"
broken dry-run-writes "red: a dry run that writes fails" "the dry run wrote nothing"
broken keeps-copy "red: a move that leaves the credential copy fails" "the copy of Argo CD's old credential is removed"
broken changes-checkout "red: a move that commits to the reader's checkout fails" "the checkout was never changed"
broken rerun-not-noop "red: a re-run that does not say Nothing to do fails the page's second success condition" "run again, it says Nothing to do"
broken stage-unsettled "red: a site that never settles on the external forge fails the setup, not a row it never reached" "GLUE: every Application is Synced and Healthy on the external repository"

# mutated copies of the path, each of which must not end PASS against the honest product
mutated() { # LABEL OLD NEW
  local d r f; f="$(mktemp "${GT}/paths/m.XXXXXX")"
  mut "$P16" "$f" "$2" "$3" 2>/dev/null || { bad "$1" "the edit changed nothing"; return; }
  d="$(sandbox)"; r="$(run_p16 "$f" "$d")"
  [ "$r" != "0|PASS" ] && ok "mutation: ${1}: not a PASS (${r})" || bad "mutation: ${1}" "the mutated copy still ended 0|PASS"
}
mutated "a path that plants no untracked file cannot show the refusal" 'printf '"'"'planted by executed-docs P16\n'"'"' > "${SITE_DIR}/p16-uncommitted.txt"' ':'
mutated "a path that leaves --dry-run in the move moves nothing" 'ZSH_PASTE_TIMEOUT="$MOVE_TIMEOUT" run_ws "$S" "$(filled "${STATE}/block.sh" | undry)"' 'ZSH_PASTE_TIMEOUT="$MOVE_TIMEOUT" run_ws "$S" "$(filled "${STATE}/block.sh")"'
mutated "a path that reads the Applications before the move as the ones after it cannot show row 1" 'apps_now "${STATE}/apps-after.json"' 'cp "${STATE}/apps-before.json" "${STATE}/apps-after.json"'
mutated "a path that never applies the staged root never puts the site on the external forge" 'kubectl --context="$KUBE_CONTEXT" apply -f "${STATE}/stage/bootstrap/root.yaml"' ':'
mutated "a path that never pushes the staged history has no external repository to move from" 'xgit -C "${STATE}/stage" push -q --force' ': xgit -C "${STATE}/stage" push -q --force'
mutated "a path that leaves a placeholder unfilled cannot run the page's block" '-e "s|YOUR_SITE_CHECKOUT|${SITE_DIR}|g"' '-e "s|YOUR_SITE_CHECKOUTX|${SITE_DIR}|g"'

# ------------------------------------------------------------------ 4. the gate
mkdir -p "${TMP}/gbin"; printf '#!/bin/sh\necho "$@" >> "%s/kcalls"\nexit 1\n' "$TMP" > "${TMP}/gbin/kubectl"; chmod +x "${TMP}/gbin/kubectl"
run_gate() { # FILE STATE-DIR [ROUTE] [FROM-DIR] ... prints "rc|receipt|kubectl calls"
  rm -rf "${TMP}/gr" "${TMP}/kcalls"
  env -u TOCKMOX_P09_ROUTE -u TOCKMOX_P16_FROM_DIR PATH="${TMP}/gbin:${BIN}:${PATH}" OUTCOME_RECEIPT_DIR="${TMP}/gr" TOCKMOX_PATH_NAME=P16-move-in-forge \
      KUBE_CONTEXT=stub-ctx TOCKMOX_DOCS_REF=HEAD TOCKMOX_P16_BUDGET=0 TOCKMOX_P16_SHELL=bash ${2:+TOCKMOX_P09_STATE="$2"} ${3:+TOCKMOX_P09_ROUTE="$3"} \
      ${4:+TOCKMOX_P16_FROM_DIR="$4"} bash "$1" > "${TMP}/gout" 2>&1
  local rc=$?
  printf '%s|%s|%s' "$rc" "$(cut -d' ' -f1 "${TMP}/gr/P16-move-in-forge" 2>/dev/null)" "$(grep -c . "${TMP}/kcalls" 2>/dev/null || echo 0)"
}
gate() { is "gate: ${1}: BLOCKED, exit 0, and no cluster call" "0|BLOCKED|0" "$(run_gate "$P16" "${2:-}" "${3:-}" "${4:-}")"; }
gd="$(sandbox)"
gate "no P09 state directory named" ""
rm "$gd/p09/p09-passed"
gate "a P09 state directory that never ended PASS (no p09-passed marker)" "$gd/p09" external "$gd/from-dir"
: > "$gd/p09/p09-passed"
gate "a P09 that passed, with no route named (a plain run.sh)" "$gd/p09" "" "$gd/from-dir"
gate "a P09 that passed on the built-in route" "$gd/p09" built-in "$gd/from-dir"
grep -q 'Run the external route' "${TMP}/gout" && ok "gate: the reason names the route to run instead" || bad "gate: reason" "$(tail -2 "${TMP}/gout")"
gate "no external forge to move from (no TOCKMOX_P16_FROM_DIR)" "$gd/p09" external ""
cp -R "$gd/from-dir" "$gd/ca-dir"; printf -- '-----BEGIN CERTIFICATE-----\nstub\n-----END CERTIFICATE-----\n' > "$gd/ca-dir/ca.crt"
gate "an external forge on a private CA" "$gd/p09" external "$gd/ca-dir"
grep -q 'passes no CA to the off-site copy' "${TMP}/gout" && ok "gate: the private-CA reason names the gap in the command" || bad "gate: CA reason" "$(tail -2 "${TMP}/gout")"
mv "$gd/p09/session.env" "$gd/p09/session.off"
gate "a P09 session that names no site repository" "$gd/p09" external "$gd/from-dir"
mv "$gd/p09/session.off" "$gd/p09/session.env"
is "gate: with all of them it goes past the gate (a spent budget stops it before any cluster call, exit 75)" "75||0" "$(run_gate "$P16" "$gd/p09" external "$gd/from-dir")"
gm="$(mktemp "${GT}/paths/g.XXXXXX")"
# shellcheck disable=SC1003  # the backslash is the line continuation in the path's text, matched literally
mut "$P16" "$gm" '[ ! -s "${FROM_DIR}/ca.crt" ] \' '[ -n "${FROM_DIR}" ] \'
case "$(run_gate "$gm" "$gd/p09" external "$gd/ca-dir")" in 0\|BLOCKED\|0) bad "mutation: a gate that does not read ca.crt" "still BLOCKED on a private CA" ;; *) ok "mutation: a gate that does not read ca.crt goes past it on a private CA, so the case above is the guard" ;; esac
# shellcheck disable=SC1003  # the backslash is the line continuation in the path's text, matched literally
mut "$P16" "$gm" '[ "${TOCKMOX_P09_ROUTE:-}" = external ] \' '[ -n "${TOCKMOX_P09_ROUTE:-x}" ] \'
case "$(run_gate "$gm" "$gd/p09" built-in "$gd/from-dir")" in 0\|BLOCKED\|0) bad "mutation: a gate that does not read the route" "still BLOCKED on the built-in route" ;; *) ok "mutation: a gate that does not read the route goes past it on the built-in route, so the case above is the guard" ;; esac
grep -F '[ -f "${P09_STATE}/p09-passed" ]' "$P16" >/dev/null && grep -E '^P16 \| BLOCKED \| nofile:TOCKMOX_P09_STATE/p09-passed \|' "${HERE}/expected-outcomes.txt" >/dev/null \
  && ok "gate: expected-outcomes.txt allows P16 BLOCKED on the marker the path itself blocks on" || bad "gate: the expected-outcomes row" "no P16 row on nofile:TOCKMOX_P09_STATE/p09-passed"

printf '\n  %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# forge-move-in.sh ... move a RUNNING site whose repository lives on an external
# forge (GitHub, another Forgejo, GitLab) into the built-in forge, with its whole
# history, and cut Argo CD over to it.
#
#   ./install/tockmox-install.sh move-in-forge --site ./my-site --context NAME \
#       --from https://github.com/me/my-site.git --from-credentials FILE \
#       -- --kit-out ~/keys/tockmox-recovery-kit.tar.age --age-recipient age1... \
#          --sealing-key-backup ~/keys/sealed-secrets.key.enc
#
# The inverse of move-forge. Everything after `--` goes to bootstrap-forge as it is
# (the recovery kit and its encryption, sign-in, namespaces), because this command
# installs the forge THROUGH bootstrap-forge rather than beside it: one installer
# path, one set of refusals.
#
# IN ORDER, every refusal before anything is written:
#   1. Refusals. The site checkout has no uncommitted or untracked change; it is on
#      main; Argo CD's root Application reads --from (in any spelling of it: https
#      or ssh, with or without .git); the checkout's main is the revision Argo CD is
#      synced to; every Application is Synced and Healthy; and if a built-in forge
#      is already installed, the history it holds is this site's (an earlier run of
#      this command), never another site's.
#   2. The migration commit, in a scratch copy (your checkout is never changed):
#      every `repoURL:` that names --from names the built-in forge's in-cluster
#      address instead, and the built-in values are added (global.siteForge:
#      built-in, sso.apps.forge.enabled: true where the identity layer is on,
#      siteForge.enabled: true where the observability layer is on). ONE commit,
#      with a fixed author and date, so a re-run makes the same commit.
#   3. A copy of Argo CD's credential for --from, beside the original, so Argo CD
#      can still read the old repository at every moment of the cutover.
#   4. bootstrap-forge installs the forge, pushes the whole history plus the
#      migration commit, protects main, and gives Argo CD its credential for the
#      forge (replacing tockmox-site-repo when that named --from). --from is NOT
#      touched yet.
#   5. The cutover: the root Application is applied from the migrated tree.
#   6. The check: every Application that read --from reads the forge, the root is
#      synced to the forge's main, every Application is Synced and Healthy, and
#      every resource each one managed before is still there (nothing pruned).
#      Then the credential copy from step 3 is removed.
#   7. Only now, unless --no-offsite-copy: bootstrap-forge again, with --from as the
#      off-site copy (a push mirror of main), which pushes the migration commit there.
#
# If step 6 does not come right within --wait-seconds, nothing is undone for you:
# it prints what is wrong and the one command that points Argo CD back at --from
# (your checkout's own bootstrap/root.yaml, which this command never changed). That
# works because --from's main is still the revision Argo CD read before: nothing is
# pushed to it until the cutover has been checked.
# A re-run after the move is a no-op: Argo CD already reads the forge.
#
# CI: the built-in forge runs no CI (its actions are off). A site that had
# workflows on --from stops running them on changes made in the forge; the push
# mirror still pushes main to --from, where they run after the fact, if at all.
# docs/administration/site-forge.md says what to do about it.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="tockmox-forge"; ORG="tockmox"; REPO="site"
ROOT_APP="tockmox-root"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; X=$'\e[0m'
else B=""; G=""; Y=""; R=""; X=""; fi
say()  { printf '\n%s== %s%s\n' "$B" "$*" "$X"; }
ok()   { printf '%s  ✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '%s  !%s %s\n' "$Y" "$X" "$*"; }
err()  { printf '%s  ✗%s %s\n' "$R" "$X" "$*" >&2; }
die()  { err "$*"; exit 1; }
info() { printf '    %s\n' "$*"; }

usage() {
  cat <<'USAGE'
tockmox-install.sh move-in-forge --site DIR --context NAME --from URL (--from-credentials FILE | --no-offsite-copy) [options] -- BOOTSTRAP-FORGE OPTIONS

Move a running site whose repository is on an external forge into the built-in forge,
with its whole history, and cut Argo CD over to it. Refuses before it writes anything.

  --site DIR              a checkout of the site repository at the revision Argo CD reads (never changed)
  --context NAME          the site's cluster (required; never the current context by default)
  --yes-context NAME      confirm it without a prompt (must equal --context); needs --yes-server
  --yes-server URL        confirm the API server the same way
  --no-prompt             never ask; refuse unless --yes-context and --yes-server confirm
  --from URL              the site repository Argo CD reads today, as https:// (its ssh spelling in the
                          site's files is matched too)
  --from-credentials FILE two lines, user then token, that can PUSH to --from: it becomes the off-site copy
  --no-offsite-copy       leave --from as it is (give bootstrap-forge another destination after --, or none)
  --namespace NS          the forge's namespace (default tockmox-forge)
  --argocd-namespace NS   default argocd
  --wait-seconds N        how long the cutover check waits (default 900)
  --accept-unsettled APP  an Application that is not Synced and Healthy before the move and that you accept
                          as it is (repeatable). It must still read the forge afterwards and lose nothing.
  --dry-run               run every refusal and show the migration commit; change nothing
  --                      the rest goes to bootstrap-forge (--kit-out, --age-recipient, ...)
  -h, --help              this
USAGE
}

SITE=""; CONTEXT=""; YES_CONTEXT=""; YES_SERVER=""; NO_PROMPT=false; FROM=""; FROM_CREDS=""
NO_OFFSITE=false; FORGE_NS="tockmox-forge"; ARGO_NS="argocd"; WAIT_S=900; DRY_RUN=false
PASS=(); ACCEPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --site) SITE="${2:?--site needs a directory}"; shift 2 ;;
    --context) CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    --yes-context) YES_CONTEXT="${2:?--yes-context needs the context name}"; shift 2 ;;
    --yes-server) YES_SERVER="${2:?--yes-server needs the API server URL}"; shift 2 ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --from) FROM="${2:?--from needs a URL}"; shift 2 ;;
    --from-credentials) FROM_CREDS="${2:?--from-credentials needs a file}"; shift 2 ;;
    --no-offsite-copy) NO_OFFSITE=true; shift ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --argocd-namespace) ARGO_NS="${2:?--argocd-namespace needs a name}"; shift 2 ;;
    --wait-seconds) WAIT_S="${2:?--wait-seconds needs a number}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --accept-unsettled) ACCEPT="${ACCEPT:+$ACCEPT,}${2:?--accept-unsettled needs an Application name}"; shift 2 ;;
    --) shift; PASS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1 (bootstrap-forge's options go after --)" ;;
  esac
done

# ---------------------------------------------------------------- the request
say "Checking the request"
[[ -n "$CONTEXT" ]] || die "--context is required: name the site's cluster. This never falls back to the current context."
[[ -z "$YES_CONTEXT" || "$YES_CONTEXT" == "$CONTEXT" ]] || die "--yes-context '$YES_CONTEXT' does not match --context '$CONTEXT'. Nothing was touched."
[[ -n "$SITE" ]] || die "--site is required: a checkout of the site repository Argo CD reads"
if [[ -n "${TOCKMOX_TEST_ALLOW_HTTP:-}" && "$FROM" =~ ^http://127\.0\.0\.1:[0-9]+/ ]]; then :
else [[ "$FROM" =~ ^https://[^@[:space:]]+/[^[:space:]]+$ ]] || die "--from must be the repository's https URL, with no credentials in it: '${FROM}'"; fi
if $NO_OFFSITE; then
  [[ -z "$FROM_CREDS" ]] || die "--no-offsite-copy and --from-credentials contradict each other"
else
  [[ -n "$FROM_CREDS" && -r "$FROM_CREDS" && "$(grep -c . "$FROM_CREDS")" -ge 2 ]] \
    || die "--from-credentials FILE is required: two lines, a user and a token that can push to $FROM, which becomes
       the off-site copy. To leave $FROM as it is, pass --no-offsite-copy instead."
fi
[[ "$WAIT_S" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a whole number: '$WAIT_S'"
[[ "$FORGE_NS" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--namespace is not a namespace name: '$FORGE_NS'"
for a in "${PASS[@]+"${PASS[@]}"}"; do
  case "$a" in
    --site|--context|--yes-context|--yes-server|--no-prompt|--replace-argocd-credential|--dry-run|--connect-sign-in|--restore-history|--namespace|--argocd-namespace)
      die "$a is this command's to set; do not pass it to bootstrap-forge after --" ;;
    --offsite-git|--offsite-git-credentials)
      $NO_OFFSITE || die "$a after --: --from is the off-site copy unless you pass --no-offsite-copy" ;;
  esac
done
for t in kubectl git python3; do command -v "$t" >/dev/null 2>&1 || die "missing: $t"; done
BOOTSTRAP="$HERE/bootstrap-forge.sh"
# The tests replace bootstrap-forge with a stand-in; only with the test switch, never otherwise.
[[ -z "${TOCKMOX_TEST_ALLOW_HTTP:-}" || -z "${TOCKMOX_TEST_BOOTSTRAP_FORGE:-}" ]] || BOOTSTRAP="$TOCKMOX_TEST_BOOTSTRAP_FORGE"
[[ -r "$BOOTSTRAP" ]] || die "missing $BOOTSTRAP"

IN_CLUSTER="http://${RELEASE}-http.${FORGE_NS}.svc.cluster.local:3000/${ORG}/${REPO}.git"
K=(--context "$CONTEXT")
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-move-in.XXXXXX")"; PF_PID=""
cleanup() { [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true; rm -rf "$TMPD"; }
trap cleanup EXIT

# One repository, any spelling: https://host/a/b(.git), ssh://git@host/a/b, git@host:a/b.git.
norm() {
  python3 - "$1" <<'PY'
import re, sys
u = sys.argv[1].strip().strip('"').strip("'")
m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$', u)
print((m.group(1).lower() + "/" + m.group(2)) if m else u)
PY
}
FROM_N="$(norm "$FROM")"; IN_N="$(norm "$IN_CLUSTER")"

# ---------------------------------------------------------------- the site checkout
say "Your site checkout"
git -C "$SITE" rev-parse --git-dir >/dev/null 2>&1 || die "$SITE is not a git checkout"
SITE="$(cd "$SITE" && pwd)"
[[ -f "$SITE/bootstrap/root.yaml" ]] || die "$SITE has no bootstrap/root.yaml; it is not a site repository"
[[ "$(git -C "$SITE" rev-parse --abbrev-ref HEAD)" == main ]] || die "$SITE is not on main; the Applications read main"
[[ -z "$(git -C "$SITE" status --porcelain)" ]] || die "$SITE has uncommitted or untracked changes:
$(git -C "$SITE" status --porcelain | head -10)
       Commit and push them (so Argo CD reads them first), or clean them away. Nothing was touched."
SITE_HEAD="$(git -C "$SITE" rev-parse HEAD)"
ok "$SITE is clean, on main at ${SITE_HEAD:0:12}"

# ---------------------------------------------------------------- the cluster
say "The cluster"
SERVER="$(kubectl config view --minify --context "$CONTEXT" -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
[[ -n "$SERVER" ]] || die "cannot read the API server address for context '$CONTEXT'. Refusing."
if [[ -n "$YES_CONTEXT" ]]; then
  [[ -n "$YES_SERVER" ]] || die "--yes-context was given without --yes-server. Re-run with --yes-server '$SERVER' if that is the one."
  [[ "$YES_SERVER" == "$SERVER" ]] || die "--yes-server '$YES_SERVER' does not match the API server in use, '$SERVER'. Nothing was touched."
elif ! $DRY_RUN; then
  $NO_PROMPT && die "--no-prompt without --yes-context and --yes-server: the cluster cannot be confirmed. Nothing was touched."
  (: < /dev/tty) 2>/dev/null || die "no terminal to confirm on. Re-run with --yes-context '$CONTEXT' --yes-server '$SERVER'."
  printf '    Move the site of %s (%s) into the built-in forge? Type the context name to go on: ' "$CONTEXT" "$SERVER" > /dev/tty
  read -r answer < /dev/tty || answer=""
  [[ "$answer" == "$CONTEXT" ]] || die "not confirmed. Nothing was touched."
fi
kubectl "${K[@]}" -n "$ARGO_NS" get applications.argoproj.io -o json > "$TMPD/apps-before.json" 2>"$TMPD/err" \
  || die "cannot list Argo CD's Applications in ${ARGO_NS}: $(tail -1 "$TMPD/err")"

# apps_check MODE: before | after FORGE_MAIN. Reads $TMPD/apps-now.json (and apps-before.json).
apps_check() {
  python3 - "$TMPD/apps-before.json" "$TMPD/apps-now.json" "$1" "$ROOT_APP" "$FROM_N" "$IN_N" "${2:-}" "$ACCEPT" <<'PY'
import json, re, sys
before_p, now_p, mode, root, from_n, in_n, forge_main, accept = sys.argv[1:9]
accept = set(x for x in accept.split(",") if x)
def norm(u):
    u = (u or "").strip()
    m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$', u)
    return (m.group(1).lower() + "/" + m.group(2)) if m else u
def load(p):
    try:
        return {a["metadata"]["name"]: a for a in json.load(open(p)).get("items", [])}
    except (OSError, ValueError, KeyError):
        return {}
def srcs(a):
    s = a.get("spec", {})
    return [x.get("repoURL", "") for x in ([s["source"]] if s.get("source") else []) + s.get("sources", [])]
def state(a):
    st = a.get("status", {})
    return st.get("sync", {}).get("status", "?"), st.get("health", {}).get("status", "?")
def res(a):
    return {(r.get("group", ""), r.get("kind", ""), r.get("namespace", ""), r.get("name", ""))
            for r in a.get("status", {}).get("resources", [])}
before = load(before_p)
bad = []
if mode == "before":
    if root not in before:
        print("NOROOT"); sys.exit(0)
    r = before[root]
    print("ROOT " + " ".join(norm(u) for u in srcs(r)) + " " + r.get("status", {}).get("sync", {}).get("revision", ""))
    for n, a in sorted(before.items()):
        s, h = state(a)
        if (s != "Synced" or h != "Healthy") and n not in accept:
            bad.append("%s is %s/%s" % (n, s, h))
    for n in sorted(accept - set(before)):
        bad.append("--accept-unsettled names %s, which is not an Application" % n)
    print("APPS %d READ_FROM %d" % (len(before), sum(1 for a in before.values() if from_n in map(norm, srcs(a)))))
    for b in bad: print("BAD " + b)
    sys.exit(0)
now = load(now_p)
for n, a in sorted(before.items()):
    if n not in now:
        bad.append("%s is gone" % n); continue
    b, c = now[n], None
    if from_n in map(norm, srcs(b)):
        bad.append("%s still reads the old repository" % n)
    s, h = state(b)
    if (s != "Synced" or h != "Healthy") and n not in accept:
        bad.append("%s is %s/%s" % (n, s, h))
    lost = res(a) - res(b)
    if lost:
        bad.append("%s no longer manages %d resource(s), e.g. %s" % (n, len(lost), "/".join(x for x in sorted(lost)[0] if x)))
r = now.get(root, {})
if in_n not in map(norm, srcs(r)):
    bad.append("%s does not read the built-in forge yet" % root)
elif forge_main and r.get("status", {}).get("sync", {}).get("revision", "") != forge_main:
    bad.append("%s is not synced to the forge's main %s yet" % (root, forge_main[:12]))
for x in bad: print("BAD " + x)
print("OK" if not bad else "WAIT %d" % len(bad))
PY
}

apps_check before > "$TMPD/before.txt"
grep -q '^NOROOT' "$TMPD/before.txt" && die "there is no Application ${ARGO_NS}/${ROOT_APP}: this command moves a Tockmox site whose root is ${ROOT_APP}"
read -r _ ROOT_SRC ROOT_REV < <(grep '^ROOT ' "$TMPD/before.txt")
if [[ "$ROOT_SRC" == "$IN_N" ]]; then
  cp "$TMPD/apps-before.json" "$TMPD/apps-now.json"
  if apps_check after "" | grep '^OK$' >/dev/null; then
    ok "Argo CD already reads the built-in forge and every Application is Synced and Healthy. Nothing to do."
    exit 0
  fi
  die "Argo CD's root already reads the built-in forge, but not every Application is settled:
$(apps_check after "" | sed -n 's/^BAD /         /p')
       Nothing was touched. Fix those, or re-run once they settle."
fi
[[ "$ROOT_SRC" == "$FROM_N" ]] || die "Argo CD's root Application reads ${ROOT_SRC}, not --from (${FROM_N}).
       This moves the repository Argo CD reads. Nothing was touched."
ok "Argo CD's root reads $FROM"
[[ "$ROOT_REV" == "$SITE_HEAD" ]] || die "Argo CD is synced to ${ROOT_REV:0:12}, but $SITE is at ${SITE_HEAD:0:12}.
       Pull (or push) so your checkout is exactly what Argo CD reads. Nothing was touched."
ok "your checkout is the revision Argo CD is synced to"
if grep -q '^BAD ' "$TMPD/before.txt"; then
  die "not every Application is Synced and Healthy, so the check after the move could not tell what the move did:
$(sed -n 's/^BAD /         /p' "$TMPD/before.txt")
       Nothing was touched. Settle them first, or name each one you accept as it is with --accept-unsettled APP."
fi
ok "$(sed -n 's/^APPS \([0-9]*\) READ_FROM \([0-9]*\)$/\1 Applications Synced and Healthy, \2 of them read the site repository/p' "$TMPD/before.txt")"

# ---------------------------------------------------------------- an earlier forge
say "The built-in forge"
FORGE_MAIN=""
if kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o name >/dev/null 2>&1; then
  ADMIN_USER="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.username}' | base64 -d)"
  ADMIN_PASS="$(kubectl "${K[@]}" -n "$FORGE_NS" get secret "${RELEASE}-admin" -o jsonpath='{.data.password}' | base64 -d)"
  FORGE_HDR="Authorization: Basic $(printf '%s:%s' "$ADMIN_USER" "$ADMIN_PASS" | base64 | tr -d '\n')"
  kubectl "${K[@]}" -n "$FORGE_NS" port-forward "svc/${RELEASE}-http" 0:3000 > "$TMPD/pf.log" 2>&1 &
  PF_PID=$!; PORT=""
  for _ in $(seq 1 30); do
    PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 3000$/\1/p' "$TMPD/pf.log" | head -1)"
    [[ -n "$PORT" ]] && break
    kill -0 "$PF_PID" 2>/dev/null || die "the port-forward to the forge exited: $(cat "$TMPD/pf.log")"
    sleep 1
  done
  [[ -n "$PORT" ]] || die "the port-forward to the forge did not start"
  FORGE_GIT="http://127.0.0.1:${PORT}/${ORG}/${REPO}.git"
  fgit() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="$FORGE_HDR" GIT_TERMINAL_PROMPT=0 git "$@"; }
  FORGE_MAIN="$(fgit ls-remote "$FORGE_GIT" refs/heads/main 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ -n "$FORGE_MAIN" ]]; then ok "a built-in forge is installed; its site repository's main is ${FORGE_MAIN:0:12}"
  else ok "a built-in forge is installed; its site repository holds nothing yet"; fi
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
else
  ok "no built-in forge yet: bootstrap-forge installs it"
fi

# ---------------------------------------------------------------- the migration commit
say "The migration commit (in a scratch copy; your checkout is not changed)"
TREE="$TMPD/tree"
git clone -q --no-local "$SITE" "$TREE"
python3 - "$TREE" "$FROM_N" "$IN_CLUSTER" > "$TMPD/rewrite.txt" <<'PY'
import os, re, sys
root, from_n, new = sys.argv[1:4]
def norm(u):
    u = u.strip().strip('"').strip("'")
    m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$', u)
    return (m.group(1).lower() + "/" + m.group(2)) if m else u
line_re = re.compile(r'^(\s*(?:-\s+)?repoURL:\s*)(["\']?)([^\s"\'#]+)\2(\s*(?:#.*)?)$')
files = lines = 0; other = {}
for d, dirs, names in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".git"]
    for n in names:
        if not n.endswith((".yaml", ".yml")): continue
        p = os.path.join(d, n)
        try: src = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError): continue
        out, hit = [], 0
        for l in src.split("\n"):
            m = line_re.match(l)
            if m and norm(m.group(3)) == from_n:
                l = m.group(1) + new + m.group(4); hit += 1
            elif m and "/" in m.group(3) and not m.group(3).startswith(("oci://",)):
                other[m.group(3)] = other.get(m.group(3), 0) + 1
            out.append(l)
        if hit:
            open(p, "w", encoding="utf-8").write("\n".join(out)); files += 1; lines += hit
print("REWROTE %d %d" % (files, lines))
for u, c in sorted(other.items()): print("KEPT %d %s" % (c, u))
PY
read -r _ NFILES NLINES < <(grep '^REWROTE ' "$TMPD/rewrite.txt")
[[ "$NLINES" -gt 0 ]] || die "no repoURL in $SITE names $FROM. Nothing was touched."
grep -q "$IN_CLUSTER" "$TREE/bootstrap/root.yaml" || die "bootstrap/root.yaml has no repoURL naming $FROM, so the root could not be cut over. Nothing was touched."
ok "$NLINES repoURL line(s) in $NFILES file(s) now name $IN_CLUSTER"
if grep -q '^KEPT ' "$TMPD/rewrite.txt"; then
  info "left as they are (other repositories):"
  sed -n 's/^KEPT \([0-9]*\) \(.*\)$/      \2 (\1)/p' "$TMPD/rewrite.txt"
fi

# The built-in values. Line edits, each refusing an ambiguous file rather than guessing.
python3 - "$TREE" > "$TMPD/values.txt" <<'PY'
import os, re, sys
root = sys.argv[1]
def rd(p):
    p = os.path.join(root, p)
    return open(p, encoding="utf-8").read().split("\n") if os.path.exists(p) else None
def wr(p, ls):
    t = "\n".join(ls)
    open(os.path.join(root, p), "w", encoding="utf-8").write(t if t.endswith("\n") else t + "\n")
def block(ls, top):  # (start, end) of a top-level key's block
    s = next((i for i, l in enumerate(ls) if re.match(r'^%s:\s*(#.*)?$' % re.escape(top), l)), None)
    if s is None: return None
    e = next((i for i in range(s + 1, len(ls)) if re.match(r'^[^\s#]', ls[i])), len(ls))
    return s, e
g = rd("site/values/global.yaml")
if g is None:
    print("FAIL site/values/global.yaml is missing")
else:
    b = block(g, "global")
    if not b:
        print("FAIL site/values/global.yaml has no global: block")
    else:
        idx = [i for i in range(b[0] + 1, b[1]) if re.match(r'^  siteForge:', g[i])]
        if idx:
            g[idx[0]] = re.sub(r'^(  siteForge:\s*)\S+', r'\1built-in', g[idx[0]]); print("SET global.siteForge: built-in")
        else:
            g.insert(b[0] + 1, "  siteForge: built-in   # the site repository is in the built-in forge (move-in-forge)")
            print("ADD global.siteForge: built-in")
        wr("site/values/global.yaml", g)
if os.path.exists(os.path.join(root, "bootstrap/applications/tockmox-identity.yaml")):
    v = rd("site/values/identity.yaml") or []
    b = block(v, "sso")
    if not b:
        v += ["", "# The built-in site forge's sign-in (move-in-forge).", "sso:", "  apps:", "    forge:", "      enabled: true"]
        print("ADD sso.apps.forge.enabled: true")
    else:
        a = next((i for i in range(b[0] + 1, b[1]) if re.match(r'^  apps:\s*(#.*)?$', v[i])), None)
        if a is None:
            if any(re.match(r'^  apps:', v[i]) for i in range(b[0] + 1, b[1])):
                print("FAIL site/values/identity.yaml writes sso.apps on one line; add forge: {enabled: true} to it by hand")
                a = -1
            else:
                v[b[0] + 1:b[0] + 1] = ["  apps:", "    forge:", "      enabled: true"]; print("ADD sso.apps.forge.enabled: true")
        if a is not None and a >= 0:
            ae = next((i for i in range(a + 1, b[1]) if re.match(r'^ {0,3}\S', v[i])), b[1])
            f = next((i for i in range(a + 1, ae) if re.match(r'^    forge:', v[i])), None)
            if f is None:
                v[a + 1:a + 1] = ["    forge:", "      enabled: true"]; print("ADD sso.apps.forge.enabled: true")
            else:
                fe = next((i for i in range(f + 1, ae) if re.match(r'^ {0,5}\S', v[i])), ae)
                en = [i for i in range(f + 1, fe) if re.match(r'^      enabled:', v[i])]
                if en: v[en[0]] = "      enabled: true"
                else: v.insert(f + 1, "      enabled: true")
                print("SET sso.apps.forge.enabled: true")
    wr("site/values/identity.yaml", v)
else:
    print("SKIP sso.apps.forge (no identity layer)")
if os.path.exists(os.path.join(root, "bootstrap/applications/tockmox-observability.yaml")):
    v = rd("site/values/observability.yaml") or []
    b = block(v, "siteForge")
    if not b:
        v += ["", "# site.forge is built-in: alert when its off-site copy falls behind (move-in-forge).", "siteForge:", "  enabled: true"]
        print("ADD siteForge.enabled: true")
    else:
        en = [i for i in range(b[0] + 1, b[1]) if re.match(r'^  enabled:', v[i])]
        if en: v[en[0]] = "  enabled: true"
        else: v.insert(b[0] + 1, "  enabled: true")
        print("SET siteForge.enabled: true")
    wr("site/values/observability.yaml", v)
else:
    print("SKIP siteForge (no observability layer)")
PY
grep -q '^FAIL ' "$TMPD/values.txt" && die "$(sed -n 's/^FAIL //p' "$TMPD/values.txt" | head -1). Nothing was touched."
sed -n 's/^\(ADD\|SET\) \(.*\)$/  ✓ \2/p; s/^SKIP \(.*\)$/    skipped: \1/p' "$TMPD/values.txt"

# One commit, deterministic: the parent's date, a fixed author, a fixed message.
PDATE="$(git -C "$TREE" log -1 --format=%cI)"
git -C "$TREE" add -A
GIT_AUTHOR_DATE="$PDATE" GIT_COMMITTER_DATE="$PDATE" git -C "$TREE" \
  -c user.name="Tockmox installer" -c user.email="installer@${RELEASE}.invalid" -c commit.gpgsign=false \
  commit -q -m "Move the site repository into the built-in forge

Every repoURL that named ${FROM} names the built-in forge's in-cluster
address instead, and the built-in forge's values are on. The history before
this commit is the site's history on ${FROM}, unchanged." \
  || die "could not make the migration commit"
MIG="$(git -C "$TREE" rev-parse HEAD)"
ok "migration commit ${MIG:0:12} on top of ${SITE_HEAD:0:12} ($(git -C "$TREE" diff --name-only HEAD~1 | grep -c .) files)"

# An earlier run's forge: carry on from what it holds, or refuse another site's history.
if [[ -n "$FORGE_MAIN" ]]; then
  kubectl "${K[@]}" -n "$FORGE_NS" port-forward "svc/${RELEASE}-http" 0:3000 > "$TMPD/pf.log" 2>&1 &
  PF_PID=$!; PORT=""
  for _ in $(seq 1 30); do
    PORT="$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) -> 3000$/\1/p' "$TMPD/pf.log" | head -1)"; [[ -n "$PORT" ]] && break; sleep 1
  done
  [[ -n "$PORT" ]] || die "the port-forward to the forge did not start"
  FORGE_GIT="http://127.0.0.1:${PORT}/${ORG}/${REPO}.git"
  fgit -C "$TREE" fetch -q "$FORGE_GIT" "+refs/heads/main:refs/remotes/forge/main" || die "cannot read the forge's main"
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
  if [[ "$FORGE_MAIN" == "$MIG" ]] || git -C "$TREE" merge-base --is-ancestor "$MIG" "$FORGE_MAIN"; then
    git -C "$TREE" reset -q --hard "$FORGE_MAIN"
    ok "the forge already holds this move (main ${FORGE_MAIN:0:12}); carrying on from there"
  elif git -C "$TREE" merge-base --is-ancestor "$FORGE_MAIN" "$MIG"; then
    ok "the forge holds an earlier point of this site's history; bootstrap-forge moves it forward"
  else
    die "the built-in forge already holds other history (main ${FORGE_MAIN:0:12} is not this site's).
       Refusing to overwrite it. Nothing was touched."
  fi
fi

if $DRY_RUN; then
  say "Dry run: nothing was changed"
  info "would: keep a copy of Argo CD's credential for $FROM, run bootstrap-forge on the migrated tree"
  info "       (--replace-argocd-credential), apply bootstrap/root.yaml from it, and wait up to ${WAIT_S}s for"
  info "       every Application to read the forge, Synced and Healthy, with nothing pruned"
  $NO_OFFSITE || info "       then run bootstrap-forge again with --offsite-git $FROM, which pushes main there"
  info "the migration commit's diff:"
  git -C "$TREE" diff --stat HEAD~1 | sed 's/^/      /'
  exit 0
fi

# ---------------------------------------------------------------- writes begin
say "Keeping Argo CD able to read $FROM during the cutover"
CRED_COPY=""
kubectl "${K[@]}" -n "$ARGO_NS" get secret -l argocd.argoproj.io/secret-type=repository -o json > "$TMPD/repo-secrets.json" 2>/dev/null \
  || die "cannot list Argo CD's repository Secrets in ${ARGO_NS}"
SRC_SECRET="$(python3 - "$TMPD/repo-secrets.json" "$FROM_N" <<'PY'
import base64, json, re, sys
def norm(u):
    m = re.match(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$', u.strip())
    return (m.group(1).lower() + "/" + m.group(2)) if m else u
for s in json.load(open(sys.argv[1])).get("items", []):
    url = base64.b64decode(s.get("data", {}).get("url", "")).decode(errors="replace")
    if norm(url) == sys.argv[2]:
        print(s["metadata"]["name"]); break
PY
)"
if [[ -n "$SRC_SECRET" ]]; then
  CRED_COPY="tockmox-site-repo-before-move"
  kubectl "${K[@]}" -n "$ARGO_NS" get secret "$SRC_SECRET" -o json | python3 -c '
import json, sys
s = json.load(sys.stdin)
m = s["metadata"]
s["metadata"] = {"name": sys.argv[1], "namespace": m["namespace"],
                 "labels": {"argocd.argoproj.io/secret-type": "repository", "app.kubernetes.io/managed-by": "tockmox-install"}}
print(json.dumps(s))' "$CRED_COPY" | kubectl "${K[@]}" apply -f - >/dev/null || die "cannot write ${ARGO_NS}/${CRED_COPY}"
  ok "${ARGO_NS}/${CRED_COPY}: a copy of ${SRC_SECRET}, removed again once the move is checked"
else
  warn "no Argo CD repository Secret names $FROM (a public repository, or a credential template): nothing to keep"
fi

say "Installing the built-in forge and pushing the site to it (bootstrap-forge)"
BF=(--site "$TREE" --context "$CONTEXT" --yes-context "$CONTEXT" --yes-server "$SERVER" --no-prompt
    --namespace "$FORGE_NS" --argocd-namespace "$ARGO_NS" --replace-argocd-credential)
bash "$BOOTSTRAP" "${BF[@]}" "${PASS[@]+"${PASS[@]}"}" \
  || die "bootstrap-forge stopped (above). Argo CD still reads $FROM; nothing was cut over. Fix what it says and run this again."
FORGE_MAIN="$(git -C "$TREE" rev-parse HEAD)"   # bootstrap-forge checked the forge's main equals it
ok "the forge holds the site's whole history; main is ${FORGE_MAIN:0:12}"

say "The cutover"
kubectl "${K[@]}" apply -f "$TREE/bootstrap/root.yaml" >/dev/null || die "cannot apply the root Application. Argo CD still reads $FROM."
ok "root Application applied from the migrated tree"

say "Checking every Application (up to ${WAIT_S}s)"
deadline=$(( $(date +%s) + WAIT_S )); RESULT=""
while :; do
  kubectl "${K[@]}" -n "$ARGO_NS" get applications.argoproj.io -o json > "$TMPD/apps-now.json" 2>/dev/null || : > "$TMPD/apps-now.json"
  RESULT="$(apps_check after "$FORGE_MAIN")"
  grep -q '^OK$' <<<"$RESULT" && break
  [[ "$(date +%s)" -lt "$deadline" ]] || break
  sleep "${TOCKMOX_TEST_POLL_S:-10}"
done
if ! grep -q '^OK$' <<<"$RESULT"; then
  err "the cutover did not settle within ${WAIT_S}s:"
  sed -n 's/^BAD /         /p' <<<"$RESULT" >&2
  info "nothing was undone. To point Argo CD back at $FROM (your checkout was never changed):"
  info "  kubectl --context $CONTEXT apply -f $SITE/bootstrap/root.yaml"
  [[ -z "$CRED_COPY" ]] || info "Argo CD can still read it: ${ARGO_NS}/${CRED_COPY} is kept until the move is checked."
  info "or wait and run this command again: it carries on from the forge's main and checks again."
  exit 1
fi
ok "every Application reads the built-in forge, Synced and Healthy, and nothing was pruned"
if [[ -n "$CRED_COPY" ]]; then
  if kubectl "${K[@]}" -n "$ARGO_NS" delete secret "$CRED_COPY" >/dev/null 2>&1; then ok "${ARGO_NS}/${CRED_COPY} removed"
  else warn "could not remove ${ARGO_NS}/${CRED_COPY}; delete it by hand"; fi
fi

if ! $NO_OFFSITE; then
  say "Making $FROM the off-site copy (bootstrap-forge again, with --offsite-git)"
  # The recovery kit is the first run's; this run's kit goes to a scratch file that is removed on exit,
  # because bootstrap-forge refuses to overwrite a kit and the forge's secrets have not changed.
  PASS2=(); prev=""
  for a in "${PASS[@]+"${PASS[@]}"}"; do
    if [[ "$prev" == --kit-out ]]; then PASS2+=("$TMPD/second-run-kit"); else PASS2+=("$a"); fi
    prev="$a"
  done
  if ! bash "$BOOTSTRAP" "${BF[@]}" --offsite-git "$FROM" --offsite-git-credentials "$FROM_CREDS" "${PASS2[@]+"${PASS2[@]}"}"; then
    err "the move is done and checked, but $FROM is not the off-site copy yet (above). Make it so with:"
    info "  $HERE/tockmox-install.sh bootstrap-forge --site <a clone of the forge's main> --context $CONTEXT \\"
    info "    --offsite-git $FROM --offsite-git-credentials $FROM_CREDS --kit-out <a NEW file> <your other options>"
    exit 2
  fi
fi

say "Done"
if $NO_OFFSITE; then info "$FROM is left as it is (--no-offsite-copy)."
else
  info "$FROM is now the off-site copy: the forge pushes main to it after every change."
  info "The token you gave must be allowed to push main there directly (a branch rule or ruleset bypass)."
  info "Block force-pushes and direct pushes to its main there for everyone but the token you gave,"
  info "so a rewrite is refused (site-forge.md, Moving a site in)."
fi
info "Your checkout still points at $FROM. Work from the forge from now on:"
info "  git clone <the forge's address>/${ORG}/${REPO}.git   (Open the repository (advanced), or Platform > Changes)"
info "The forge runs no CI; workflows on $FROM no longer gate a change. site-forge.md says what that means."

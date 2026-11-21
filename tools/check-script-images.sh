#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY IMAGE A SCRIPT CAN RUN IS ONE THE IMAGE SET CARRIES.
#
# images.txt is the product's image set, and an air-gapped mirror holds it together with the closed
# set's extras (tests/executed-docs/lib/closed-set.sh). The charts reach images.txt through
# tools/gen-images.sh. An image that a script under install/ or tools/ pins for itself reaches it only
# when something reads the pin, and for the secret mint nothing did: it pinned an ntfy tag that
# images.txt no longer carried, so on a node that pulls only from its mirror the pod that hashes the
# ntfy password could not start and the mint wrote nothing. This gate makes that a build failure.
#
# WHAT IT READS. Every shell script under install/ and tools/ (a .sh file, or a file whose first line
# names bash or sh), except this one, whose selftest fixtures would read as pins. On each line that is
# not a comment:
#   - a literal default in a variable whose name contains IMAGE: NAME="repo:tag" or
#     NAME="${OVERRIDE:-repo:tag}";
#   - a repository and a tag pinned apart: a variable whose name contains IMAGE and TAG is joined to
#     the one beside it named with REPO for TAG, or to the repository its COMPOSE row names;
#   - --image=repo:tag or --image repo:tag, written out;
#   - a literal repo:tag on a docker, podman or nerdctl run line.
# A reference counts only with a tag or a digest, and only as a literal: a value built from another
# variable is not read, the literal it defaults to is. An untagged name (the kit's own image, built on
# the machine that runs it) is not a pull from a mirror and is not read.
#
# WHERE A REFERENCE MAY BE FOUND. In images.txt, or in the closed set's extras that need no network:
# the harness's git server and clone probe, which closed-set.sh reads from site-repo-server.sh and this
# gate reads the same way (it refuses, exit 2, when closed-set.sh stops reading them like that). The
# closed set's other extras (k3s's own images, the Argo CD and sealed-secrets charts) come from a
# download and a render, so they are not read here; a script image that only they carry needs an
# EXCEPTIONS row that says so. Docker Hub's short forms are the same image as the long ones
# (busybox:1 is docker.io/library/busybox:1), and a set entry with a digest also serves its tag.
#
#   tools/check-script-images.sh [--tree DIR]   check the tree (default: this repository)
#   tools/check-script-images.sh --selftest     red on each planted mismatch, green on the revert
#
# Exit 0 every reference is in the set or excepted; 1 a miss, or a COMPOSE or EXCEPTIONS row that no
# longer matches anything (a stale row would hide the next miss on that line); 2 bad input (no
# images.txt, an unreadable closed-set input, a row with no reason, a scan that found no reference).
# Bash 3.2 and BSD tools: no associative arrays, no mapfile, no GNU-only options.
set -uo pipefail

# EXCEPTIONS: a reference a script may run that the set does not carry. One row a line:
#   file|reference|reason
# The reason is required. A row that matches no reference fails the gate, so the change that closes a
# gap takes its row out in the same commit.
EXCEPTIONS='
install/bootstrap-secrets.sh|docker.io/bitnami/sealed-secrets-controller:0.40.0|OPEN GAP: bootstrap-secrets --mode new installs the upstream sealed-secrets chart and this controller, which neither images.txt nor the closed set carries (the closed set renders the Bitnami chart that fresh-install.md installs by hand, whose controller is a later release), so --mode new cannot pull it on a mirror-only node
'

# COMPOSE: how a tag pinned in a variable of its own becomes a reference. One row a line:
#   file|tag variable|repository|tag suffix|reason
# An empty repository means the variable beside it, named with REPO for TAG. The reason is required,
# and a row whose variable the file no longer pins fails the gate.
COMPOSE='
install/bootstrap-forge.sh|FORGE_IMAGE_TAG_DEFAULT||-rootless|the forgejo chart runs its rootless variant and appends the suffix to the tag itself, which is how tools/gen-images.sh writes it into images.txt
install/bootstrap-secrets.sh|IMAGE_TAG_DEFAULT|docker.io/bitnami/sealed-secrets-controller||the script sets only image.tag, so the repository is the upstream chart default (registry docker.io, repository bitnami/sealed-secrets-controller)
'

SELF="tools/check-script-images.sh"
die2() { echo "check-script-images: $*" >&2; exit 2; }

# The closed set's harness extras, read the way closed-set.sh reads them. These three strings are its
# own lines; when they change there, this gate stops instead of reading a list closed-set.sh no longer
# prints.
# shellcheck disable=SC2016  # closed-set.sh's own text, matched literally
CS_SRS='SRS="$TREE/tests/executed-docs/provision/site-repo-server.sh"'
# shellcheck disable=SC2016
CS_SED='sed -n '\''s/^IMAGE="\${TOCKMOX_GIT_IMAGE:-\([^}]*\)}"$/\1/p'\'' "$SRS"'
# shellcheck disable=SC2016
CS_GREP='grep -o -- '\''--image=[^ ]*'\'' "$SRS" | sed '\''s/--image=//'\'' | sort -u'

harness_extras() {  # TREE -> the harness images on stdout
  local cs="$1/tests/executed-docs/lib/closed-set.sh" srs="$1/tests/executed-docs/provision/site-repo-server.sh" l
  [ -r "$cs" ] || die2 "cannot read $cs"
  for l in "$CS_SRS" "$CS_SED" "$CS_GREP"; do
    grep -F -- "$l" "$cs" >/dev/null || die2 "closed-set.sh no longer has the line this gate reads its harness images by: $l"
  done
  [ -r "$srs" ] || die2 "cannot read $srs"
  # shellcheck disable=SC2016  # a literal ${ in the file, as closed-set.sh matches it
  sed -n 's/^IMAGE="\${TOCKMOX_GIT_IMAGE:-\([^}]*\)}"$/\1/p' "$srs"
  grep -o -- '--image=[^ ]*' "$srs" | sed 's/--image=//' | sort -u
}

list_scripts() {  # TREE -> absolute paths of the scripts in scope, sorted
  local f first
  { [ -d "$1/install" ] && find "$1/install" -type f; [ -d "$1/tools" ] && find "$1/tools" -type f; } \
    | grep -v -e '/node_modules/' -e '/__pycache__/' | LC_ALL=C sort | while IFS= read -r f; do
    [ "${f#"$1"/}" = "$SELF" ] && continue
    case "$f" in *.sh) echo "$f"; continue ;; esac
    first="$(head -n 1 "$f" 2>/dev/null || true)"
    case "$first" in '#!'*bash*|'#!'*/sh|'#!'*'/sh '*|'#!'*'env sh'*) echo "$f" ;; esac
  done
}

write_awk() {  # DIR -> extract.awk and resolve.awk
  cat > "$1/extract.awk" <<'AWK'
# stdin: one script path a line. stdout: file<TAB>line<TAB>kind<TAB>name<TAB>value, kind ref, tag or repo.
function literal(v,   q, i) {
  q = sprintf("%c", 39)
  sub(/^[ \t]+/, "", v)
  if (substr(v, 1, 1) == "\"") { v = substr(v, 2); i = index(v, "\""); if (i == 0) return ""; v = substr(v, 1, i - 1) }
  else if (substr(v, 1, 1) == q) { v = substr(v, 2); i = index(v, q); if (i == 0) return ""; v = substr(v, 1, i - 1) }
  else sub(/[ \t;|&)].*$/, "", v)
  if (match(v, /^\$\{[A-Za-z_][A-Za-z0-9_]*:?-/)) {
    v = substr(v, RLENGTH + 1)
    if (substr(v, length(v)) != "}") return ""
    v = substr(v, 1, length(v) - 1)
  }
  if (index(v, "$") || index(v, "`")) return ""
  return v
}
function isimg(v,   s, last, name) {
  if (v !~ /^[a-z0-9][a-z0-9._-]*(:[0-9]+)?(\/[a-z0-9._-]+)*(:[A-Za-z0-9_][A-Za-z0-9._-]*)?(@sha256:[0-9a-f]+)?$/) return 0
  s = v; sub(/@sha256:.*$/, "", s)
  last = s; sub(/^.*\//, "", last)
  if (index(last, ":") == 0 && index(v, "@sha256:") == 0) return 0
  name = s; sub(/:[^:\/]*$/, "", name)
  return name ~ /[a-z]/
}
function out(f, l, kind, nm, v) { printf "%s\t%d\t%s\t%s\t%s\n", f, l, kind, nm, v }
{
  path = $0; rel = path
  if (index(path, root) == 1) rel = substr(path, length(root) + 1)
  n = 0
  while ((getline line < path) > 0) {
    n++
    s = line; sub(/^[ \t]+/, "", s)
    if (s == "" || substr(s, 1, 1) == "#") continue
    k = split(s, seg, /;[ \t]*/)
    for (j = 1; j <= k; j++) {
      t = seg[j]
      if (!match(t, /^(export[ \t]+|local[ \t]+|readonly[ \t]+|declare[ \t]+-[A-Za-z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/)) continue
      nm = substr(t, 1, RLENGTH - 1); sub(/^.*[ \t]/, "", nm)
      up = toupper(nm)
      if (index(up, "IMAGE") == 0) continue
      v = literal(substr(t, RLENGTH + 1))
      if (v == "") continue
      if (index(up, "TAG")) { if (v ~ /^[A-Za-z0-9_][A-Za-z0-9._-]*$/) out(rel, n, "tag", nm, v) }
      else if (index(up, "REPO")) out(rel, n, "repo", nm, v)
      else if (isimg(v)) out(rel, n, "ref", nm, v)
    }
    t = s
    while (match(t, /--image[= ][ \t]*[^ \t;|&)]+/)) {
      tok = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
      sub(/^--image[= ][ \t]*/, "", tok)
      v = literal(tok)
      if (v != "" && isimg(v)) out(rel, n, "ref", "--image", v)
    }
    t = " " s
    if (match(t, /[ \t;|&(](docker|podman|nerdctl)[ \t]+run[ \t]/)) {
      t = substr(t, RSTART + RLENGTH)
      k = split(t, w, /[ \t]+/)
      for (j = 1; j <= k; j++) { v = literal(w[j]); if (v != "" && isimg(v)) out(rel, n, "ref", "run", v) }
    }
  }
  close(path)
}
AWK
  cat > "$1/resolve.awk" <<'AWK'
# -v setf compf excf recf nscripts. Prints each miss, exception and stale row; exits 0, 1 or 2.
function norm(r,   i, first) {
  i = index(r, "/")
  if (i == 0) return "docker.io/library/" r
  first = substr(r, 1, i - 1)
  if (first !~ /[.:]/ && first != "localhost") r = "docker.io/" r
  if (r ~ /^docker\.io\/[^\/]+$/) r = "docker.io/library/" substr(r, 11)
  return r
}
function repo_of(r) { sub(/@sha256:.*$/, "", r); if (match(r, /:[^:\/]*$/)) r = substr(r, 1, RSTART - 1); return r }
function base_of(r) { r = repo_of(r); sub(/^.*\//, "", r); return r }
function nearest(k,   i, rp, bs, hit) {
  rp = repo_of(k); bs = base_of(k); hit = ""
  for (i = 1; i <= ns; i++) if (srepo[i] == rp) hit = hit (hit == "" ? "" : ", ") sorig[i]
  if (hit != "") return hit
  for (i = 1; i <= ns; i++) if (sbase[i] == bs) hit = hit (hit == "" ? "" : ", ") sorig[i]
  if (hit != "") return hit " (same name, another repository)"
  return "none (no entry has that repository or that name)"
}
BEGIN {
  FS = "\t"
  while ((getline e < setf) > 0) {
    if (e == "" || e ~ /^#/) continue
    ns++; sorig[ns] = e; k = norm(e); have[k] = 1
    d = k; sub(/@sha256:.*$/, "", d); have[d] = 1
    srepo[ns] = repo_of(k); sbase[ns] = base_of(k)
  }
  while ((getline e < compf) > 0) {
    split(e, c, "|"); key = c[1] SUBSEP c[2]
    crepo[key] = c[3]; csuf[key] = c[4]; nc++; corder[nc] = key; cshow[key] = c[1] "|" c[2]
  }
  while ((getline e < excf) > 0) {
    split(e, x, "|"); key = x[1] SUBSEP norm(x[2])
    xreason[key] = x[3]; nx++; xorder[nx] = key; xshow[key] = x[1] "|" x[2]
  }
  while ((getline e < recf) > 0) {
    nr++; split(e, f, "\t")
    rf[nr] = f[1]; rl[nr] = f[2]; rk[nr] = f[3]; rn[nr] = f[4]; rv[nr] = f[5]
    if (f[3] == "repo") repov[f[1] SUBSEP f[4]] = f[5]
  }
  for (i = 1; i <= nr; i++) {
    if (rk[i] == "repo") continue
    ref = rv[i]; what = rn[i]
    if (rk[i] == "tag") {
      key = rf[i] SUBSEP rn[i]; partner = rn[i]; sub(/TAG/, "REPO", partner)
      repo = ""; suf = ""
      if (key in crepo) { cused[key] = 1; repo = crepo[key]; suf = csuf[key] }
      if (repo == "" && ((rf[i] SUBSEP partner) in repov)) repo = repov[rf[i] SUBSEP partner]
      if (repo == "") {
        printf "MISS %s:%s: %s pins the tag %s with no repository beside it (no %s); name the repository in a COMPOSE row\n", rf[i], rl[i], rn[i], rv[i], partner
        miss++; total++; continue
      }
      ref = repo ":" rv[i] suf
    }
    total++
    k = norm(ref)
    if (k in have) { found++; continue }
    if ((rf[i] SUBSEP k) in xreason) {
      xused[rf[i] SUBSEP k] = 1; exc++
      printf "excepted %s:%s: %s (%s): %s\n", rf[i], rl[i], ref, what, xreason[rf[i] SUBSEP k]
      continue
    }
    miss++
    printf "MISS %s:%s: %s (%s) is not in images.txt or the closed set's extras; nearest set entry: %s\n", rf[i], rl[i], ref, what, nearest(k)
  }
  for (i = 1; i <= nc; i++) if (!(corder[i] in cused)) { stale++; printf "STALE COMPOSE ROW %s: that file pins no such tag variable; take the row out\n", cshow[corder[i]] }
  for (i = 1; i <= nx; i++) if (!(xorder[i] in xused)) { stale++; printf "STALE EXCEPTION %s: no script there runs that reference any more; take the row out\n", xshow[xorder[i]] }
  if (total == 0) { print "check-script-images: the scan found no image reference in " nscripts " scripts; the scan is broken, not the tree" > "/dev/stderr"; exit 2 }
  printf "check-script-images: %d image references in %d scripts: %d in the set, %d excepted, %d missing, %d stale rows\n", total, nscripts, found, exc, miss, stale
  exit (miss + stale > 0) ? 1 : 0
}
AWK
}

check() {  # TREE
  local tree="$1" w rc nscripts
  [ -d "$tree" ] || die2 "no such tree: $tree"
  tree="$(cd "$tree" && pwd)"
  [ -s "$tree/images.txt" ] || die2 "cannot read $tree/images.txt"
  w="$(mktemp -d "${TMPDIR:-/tmp}/check-script-images.XXXXXX")" || die2 "cannot make a temporary directory"
  # shellcheck disable=SC2064  # expand now: w is local
  trap "rm -rf '$w'" EXIT
  harness_extras "$tree" > "$w/extras"
  [ -s "$w/extras" ] || die2 "the closed set's harness images came back empty from site-repo-server.sh"
  { grep -v -e '^#' -e '^$' "$tree/images.txt"; cat "$w/extras"; } > "$w/set"
  printf '%s\n' "$EXCEPTIONS" | sed '/^[[:space:]]*$/d' > "$w/exc"
  printf '%s\n' "$COMPOSE" | sed '/^[[:space:]]*$/d' > "$w/comp"
  awk -F'|' 'NF != 3 || $1 == "" || $2 == "" || $3 ~ /^[[:space:]]*$/ { print "bad EXCEPTIONS row (file|reference|reason): " $0; bad = 1 } END { exit bad }' "$w/exc" >&2 \
    || die2 "every EXCEPTIONS row needs a file, a reference and a reason"
  awk -F'|' 'NF != 5 || $1 == "" || $2 !~ /TAG/ || $5 ~ /^[[:space:]]*$/ { print "bad COMPOSE row (file|tag variable|repository|suffix|reason): " $0; bad = 1 } END { exit bad }' "$w/comp" >&2 \
    || die2 "every COMPOSE row needs a file, a tag variable and a reason"
  list_scripts "$tree" > "$w/scripts"
  nscripts="$(wc -l < "$w/scripts" | tr -d ' ')"
  [ "$nscripts" -gt 0 ] || die2 "no script under $tree/install or $tree/tools"
  write_awk "$w"
  awk -v root="$tree/" -f "$w/extract.awk" "$w/scripts" > "$w/recs" || die2 "the scan of the scripts failed"
  awk -v setf="$w/set" -v compf="$w/comp" -v excf="$w/exc" -v recf="$w/recs" -v nscripts="$nscripts" -f "$w/resolve.awk"
  rc=$?
  [ "$rc" = 1 ] && echo "check-script-images: put the image in the chart or images.txt, change the pin to one the set carries, or add an EXCEPTIONS row with a reason" >&2
  return "$rc"
}

# ---- selftest: a fixture tree, the real closed-set.sh, and this script with its own tables ----
ST=""; ST_FAILS=0; ST_CASES=0; ST_OUT=""; ST_RC=0
st_edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }  # FILE SED-EXPRESSION
st_build() {
  local t="$ST/t"
  rm -rf "$t"; mkdir -p "$t/install" "$t/tools" "$t/tests/executed-docs/lib" "$t/tests/executed-docs/provision"
  cp "$ST_ME" "$t/tools/check-script-images.sh"
  cp "$ST_CS" "$t/tests/executed-docs/lib/closed-set.sh"
  printf '%s\n' '# fixture' 'alpine/k8s:1.37.2' 'binwiederhier/ntfy:v2.37.2' \
    'code.forgejo.org/forgejo/forgejo:15.0.11-rootless' 'docker.io/library/busybox:1.38.0' \
    'quay.io/example/tool:v1@sha256:0123abcd' > "$t/images.txt"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'IMAGE="${TOCKMOX_GIT_IMAGE:-alpine:3.20}"' \
    '  kubectl run probe --image=alpine/git:latest --command -- true' > "$t/tests/executed-docs/provision/site-repo-server.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'FORGE_IMAGE_REPO_DEFAULT="code.forgejo.org/forgejo/forgejo"' \
    'FORGE_IMAGE_TAG_DEFAULT="15.0.11"' 'MOVE_IMAGE_DEFAULT="alpine/k8s:1.37.2"' \
    'MOVE_IMAGE="${IMAGE_REGISTRY:+${IMAGE_REGISTRY%/}/}${MOVE_IMAGE_DEFAULT}"' \
    'kubectl apply --image "$MOVE_IMAGE"' > "$t/install/bootstrap-forge.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'IMAGE_TAG_DEFAULT="0.40.0"' > "$t/install/bootstrap-secrets.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' '# NTFY_IMAGE="binwiederhier/ntfy:v0.0.1" is a comment and not read' \
    'NTFY_IMAGE="binwiederhier/ntfy:v2.37.2"' 'kubectl run x --image="$NTFY_IMAGE"' > "$t/tools/mint-secrets.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'IMAGE="${PROBE_IMAGE:-busybox:1.38.0}"' "GIT_IMAGE='alpine:3.20'" \
    'docker run --rm -v /a:/b -p 8080:80 quay.io/example/tool:v1 true' > "$t/tools/probe.sh"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/usr/bin/env bash' 'KIT_IMAGE=alpine/k8s:1.37.2' 'KIT_LOCAL_IMAGE="${X:-tockmox-kit}"' > "$t/tools/kit"
  printf '%s\n' 'NOTES_IMAGE="nope/none:1" is in a file that is not a script' > "$t/tools/notes.txt"
}
st_expect() {  # CODE LABEL [TEXT...]: run the fixture's checker and want that exit and every TEXT in its output
  local want="$1" label="$2" p ok=1; shift 2
  ST_CASES=$((ST_CASES + 1))
  ST_OUT="$(bash "$ST/t/tools/check-script-images.sh" --tree "$ST/t" 2>&1)"; ST_RC=$?
  [ "$ST_RC" = "$want" ] || ok=0
  for p in "$@"; do case "$ST_OUT" in *"$p"*) ;; *) ok=0 ;; esac; done
  if [ "$ok" = 1 ]; then echo "ok    $label (exit $ST_RC)"
  else
    ST_FAILS=$((ST_FAILS + 1)); echo "FAIL  $label: wanted exit $want and every expected text, got exit $ST_RC:"
    printf '%s\n' "$ST_OUT" | sed 's/^/        /'
  fi
}
selftest() {
  ST="$(mktemp -d "${TMPDIR:-/tmp}/check-script-images-selftest.XXXXXX")" || die2 "cannot make a temporary directory"
  # shellcheck disable=SC2064
  trap "rm -rf '$ST'" EXIT
  ST_ME="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  ST_CS="$(cd "$(dirname "$0")/.." && pwd)/tests/executed-docs/lib/closed-set.sh"
  [ -r "$ST_CS" ] || die2 "selftest: cannot read $ST_CS"
  local t="$ST/t"

  st_build; st_expect 0 "the fixture is clean: short and long names, a digest entry, a harness image, an exception, both COMPOSE rows" \
    "0 missing" "excepted install/bootstrap-secrets.sh:2: docker.io/bitnami/sealed-secrets-controller:0.40.0"
  st_edit "$t/tools/mint-secrets.sh" 's/ntfy:v2\.37\.2/ntfy:v2.28.0/'
  st_expect 1 "a variable pin the set does not carry" \
    "MISS tools/mint-secrets.sh:3: binwiederhier/ntfy:v2.28.0 (NTFY_IMAGE)" "nearest set entry: binwiederhier/ntfy:v2.37.2"
  st_edit "$t/tools/mint-secrets.sh" 's/ntfy:v2\.28\.0/ntfy:v2.37.2/'
  st_expect 0 "the same pin reverted" "0 missing"

  st_build; echo 'kubectl run y --image=docker.io/library/busybox:9.9' >> "$t/tools/probe.sh"
  st_expect 1 "a literal --image=" "MISS tools/probe.sh:5: docker.io/library/busybox:9.9 (--image)" "nearest set entry: docker.io/library/busybox:1.38.0"
  st_build; echo 'kubectl run y --image busybox:9.9' >> "$t/tools/probe.sh"
  st_expect 1 "a literal --image with a space" "MISS tools/probe.sh:5: busybox:9.9 (--image)"
  st_build; st_edit "$t/tools/probe.sh" 's/tool:v1 true/tool:v2 true/'
  st_expect 1 "a literal on a docker run line" "MISS tools/probe.sh:4: quay.io/example/tool:v2 (run)"
  st_build; st_edit "$t/tools/kit" 's/k8s:1\.37\.2/k8s:1.37.1/'
  st_expect 1 "a script with no .sh, read by its first line" "MISS tools/kit:2: alpine/k8s:1.37.1"
  st_build; st_edit "$t/install/bootstrap-forge.sh" 's/TAG_DEFAULT="15\.0\.11"/TAG_DEFAULT="15.0.12"/'
  st_expect 1 "a tag pinned apart from its repository" \
    "MISS install/bootstrap-forge.sh:3: code.forgejo.org/forgejo/forgejo:15.0.12-rootless" "nearest set entry: code.forgejo.org/forgejo/forgejo:15.0.11-rootless"
  st_build; st_edit "$t/tools/check-script-images.sh" '/^install\/bootstrap-forge\.sh|FORGE_IMAGE_TAG_DEFAULT|/d'
  st_expect 1 "the COMPOSE row that adds a chart's suffix, removed" "MISS install/bootstrap-forge.sh:3: code.forgejo.org/forgejo/forgejo:15.0.11 ("
  st_build; echo 'OTHER_IMAGE_TAG="1.0"' >> "$t/tools/probe.sh"
  st_expect 1 "a tag with no repository and no COMPOSE row" "MISS tools/probe.sh:5: OTHER_IMAGE_TAG pins the tag 1.0 with no repository"
  st_build; st_edit "$t/install/bootstrap-secrets.sh" 's/0\.40\.0/0.41.2/'
  st_expect 1 "a gap closed without taking its exception out" \
    "STALE EXCEPTION install/bootstrap-secrets.sh|docker.io/bitnami/sealed-secrets-controller:0.40.0" "MISS install/bootstrap-secrets.sh:2"
  st_build; st_edit "$t/install/bootstrap-forge.sh" 's/FORGE_IMAGE_TAG_DEFAULT=/FORGE_TAG_DEFAULT=/'
  st_expect 1 "a COMPOSE row whose variable is gone" "STALE COMPOSE ROW install/bootstrap-forge.sh|FORGE_IMAGE_TAG_DEFAULT"
  st_build; st_edit "$t/tests/executed-docs/provision/site-repo-server.sh" 's/alpine:3\.20/alpine:3.21/'
  st_expect 1 "the harness image the closed set reads, moved" "MISS tools/probe.sh:3: alpine:3.20 (GIT_IMAGE)"
  st_build; st_edit "$t/tools/check-script-images.sh" '/^install\/bootstrap-secrets\.sh|docker/s/|OPEN GAP: .*$/| /'
  st_expect 2 "an exception with no reason" "every EXCEPTIONS row needs"
  st_build; rm "$t/images.txt"
  st_expect 2 "no images.txt" "cannot read"
  st_build; st_edit "$t/tests/executed-docs/lib/closed-set.sh" 's/TOCKMOX_GIT_IMAGE:-/TOCKMOX_HARNESS_GIT_IMAGE:-/'
  st_expect 2 "closed-set.sh reading its harness images another way" "closed-set.sh no longer has the line"
  st_build; printf '%s\n' '#!/usr/bin/env bash' 'true' > "$t/tools/probe.sh"; : > "$t/tools/mint-secrets.sh"; : > "$t/tools/kit"
  printf '%s\n' '#!/usr/bin/env bash' > "$t/install/bootstrap-forge.sh"; printf '%s\n' '#!/usr/bin/env bash' > "$t/install/bootstrap-secrets.sh"
  st_expect 2 "a scan that finds no reference at all" "the scan is broken"

  echo "check-script-images selftest: ${ST_CASES} cases, ${ST_FAILS} failed"
  [ "$ST_FAILS" = 0 ]
}

TREE_ARG=""; MODE=check
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) [ $# -ge 2 ] || die2 "--tree needs a directory"; TREE_ARG="$2"; shift 2 ;;
    --selftest) MODE=selftest; shift ;;
    *) die2 "unknown argument: $1 (usage: check-script-images.sh [--tree DIR] | --selftest)" ;;
  esac
done
if [ "$MODE" = selftest ]; then selftest; exit $?; fi
[ -n "$TREE_ARG" ] || TREE_ARG="$(cd "$(dirname "$0")/.." && pwd)"
check "$TREE_ARG"

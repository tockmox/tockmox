#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# train-morning.sh ... the morning after the overnight train produced a release
# candidate: bind the maintainer's signature to exactly what was tested, in one run.
#
#   tools/train-morning.sh SPEC          REPORT ONLY (default): run every check, print every
#                                        command it would run with its values resolved, change nothing
#   tools/train-morning.sh SPEC --go     do it
#   tools/train-morning.sh --selftest    prove each refusal in throwaway repos under /tmp/pt-morning
#
# WHY. A patch release was about seventeen relayed actions: read the packet, find
# the SHA, merge the template re-pin, fast-forward, tag, sign, checksum, upload,
# each one a place to copy the wrong value or do the steps in the wrong order.
# The overnight train (a bot) builds and proves the candidate on a train/X.Y.Z
# branch; it holds no key and cannot push main, release-* or a tag. Everything
# that needs the maintainer's signature happens here, once, in a fixed order.
#
# SAFETY CONTRACT.
#   - The candidate SHA comes from THIS machine's git (origin/TRAIN_BRANCH after a
#     fetch), never from the packet. It must equal head_sha in WITNESS, the lab
#     executor's own results file, which the train cannot write.
#   - origin/REL_BRANCH must be an ancestor of the SHA: the fast-forward is a plain
#     push, never --force, and git refuses anything else.
#   - The diff origin/REL_BRANCH..SHA may touch none of FORBIDDEN (below): the trust
#     root, the security contact, the verification page, the workflows, the Renovate
#     config and the release tools. A train that edits those is not a patch.
#   - The required workflows (REQUIRED) must have a green run on that exact SHA, and
#     any OPTIONAL one that ran must be green.
#   - The tag may not already exist on another commit; SIGNING_KEY must be the key
#     .gitsigners (at the SHA) vouches for, checked BEFORE anything is signed.
#   - Order (council ruling): verify, merge the template re-pin, fast-forward, tag,
#     sign the gate report and write SHA256SUMS, publish with --verify-tag. The
#     re-pin merges before the tag because release-tag.yaml goes red otherwise;
#     the Release is created last and with --verify-tag so GitHub can never create
#     an unsigned tag on our behalf.
#   - Report-only is the default. The checks run for real (they only read); every
#     mutation is printed as "would run: $ ..." and skipped. --go runs them in that
#     order, stopping at the first failure.
# RESUMABLE. Rerun with the same SPEC after a stop. A step whose end state already
# holds (branch at the SHA, tag on the SHA and verified, .sig that verifies,
# SHA256SUMS that checks, Release with every asset) is skipped with a message.
#
# SPEC is a bash file of assignments. Paths are absolute.
#   REPO             clone of the product repo        default $HOME/src/tockmox-oss
#   GH_REPO          owner/repo on GitHub             default tockmox/tockmox
#   REL_BRANCH       release-0.8
#   TRAIN_BRANCH     train/0.8.2
#   TAG              v0.8.2
#   WITNESS          the executor's results file (JSON with "head_sha"), e.g. runs/<id>/run.json
#   TEMPLATE_PIN_PR  number of the re-pin PR in TEMPLATE_REPO (default tockmox/tockmox-site-template)
#   GATE_REPORT      the drafted GATE-REPORT-vX.Y.Z.md
#   SIGNING_KEY      private half of the tag key; its public half must be in .gitsigners
#   RELEASE_NOTES    the drafted Release body (the CHANGELOG section)
#   ANNOUNCE         optional: a Discussions category; adds --discussion-category
#   DIST_DIR         where the archive and SHA256SUMS go  default <spec dir>/dist-TAG
#   TRAIN_LOG        the one-line log                      default $HOME/src/_train-log.txt
#
# ON THE CI EVIDENCE. ci.yaml runs on pull_request and on pushes to main and
# release-*; a push to train/** starts nothing. The runs on the SHA therefore come
# from the train's PR against REL_BRANCH. Because the fast-forward is a fast-forward,
# the synthetic merge commit a pull_request run tests has the SHA's tree, and the
# push to REL_BRANCH in step 3 starts the push-event runs on the SHA itself; the
# event of each run is printed so the gate report can say which it was.
#
# Requires git 2.34+, gh (authenticated), ssh-keygen, python3, sha256sum or shasum.
# macOS bash 3.2 clean: no associative arrays, no mapfile.
set -euo pipefail

# The paths a train may not touch. A hit anywhere in origin/REL_BRANCH..SHA stops
# the run before anything is merged, pushed or signed. ** matches any depth.
FORBIDDEN=(
  ".gitsigners"
  "SECURITY.md"
  "docs/**/verify.md"
  ".github/**"
  "renovate.json5"
  "tools/release-preflight.sh"
  "tools/train-morning.sh"
  "tools/site-pin-at-tag.sh"
)

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TAG_RE='^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$'

usage() { sed -n '7,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2; }

say()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
stop() { echo; echo "STOP: $*" >&2; exit 1; }
q()    { printf '%q' "$1"; }
# act CMD-STRING: print the command with its values resolved; run it only under --go.
# Every mutation goes through here, so the report is the exact list of what --go does.
act() {
  ACTIONS=$((ACTIONS + 1))
  if [ "$GO" = 1 ]; then printf '    $ %s\n' "$*"; eval "$*"
  else printf '    would run: $ %s\n' "$*"; fi
}
sha256_tool() { if command -v sha256sum >/dev/null 2>&1; then echo "sha256sum"; else echo "shasum -a 256"; fi; }

# ---------------------------------------------------------------- spec
load_spec() {
  SPEC="$1"
  [ -f "$SPEC" ] || stop "no spec $SPEC"
  REPO="$HOME/src/tockmox-oss"; GH_REPO="tockmox/tockmox"
  TEMPLATE_REPO="tockmox/tockmox-site-template"
  REQUIRED="ci policy-gate"; OPTIONAL="executed-docs"
  TRAIN_LOG="$HOME/src/_train-log.txt"; ANNOUNCE=""; DIST_DIR=""
  REL_BRANCH=""; TRAIN_BRANCH=""; TAG=""; WITNESS=""; TEMPLATE_PIN_PR=""
  GATE_REPORT=""; SIGNING_KEY=""; RELEASE_NOTES=""
  # shellcheck disable=SC1090
  . "$SPEC"
  for v in REL_BRANCH TRAIN_BRANCH TAG WITNESS TEMPLATE_PIN_PR GATE_REPORT SIGNING_KEY RELEASE_NOTES; do
    eval "val=\${$v:-}"; [ -n "$val" ] || stop "spec is missing $v"
  done
  printf '%s\n' "$TAG" | grep -Eq "$TAG_RE" || stop "TAG '$TAG' is not vX.Y.Z (this script cuts finals; an rc is not a morning)"
  case "$TEMPLATE_PIN_PR" in ''|*[!0-9]*) stop "TEMPLATE_PIN_PR '$TEMPLATE_PIN_PR' is not a PR number" ;; esac
  for f in "$WITNESS" "$GATE_REPORT" "$RELEASE_NOTES"; do [ -s "$f" ] || stop "spec names a file that is missing or empty: $f"; done
  [ -r "$SIGNING_KEY" ] || stop "cannot read SIGNING_KEY $SIGNING_KEY"
  [ -d "$REPO/.git" ] || stop "REPO $REPO is not a git clone"
  [ -n "$DIST_DIR" ] || DIST_DIR="$(cd "$(dirname "$SPEC")" && pwd)/dist-$TAG"
  VER="${TAG#v}"
  ARCHIVE="$DIST_DIR/tockmox-${VER}.tar.gz"
  for t in git gh ssh-keygen python3; do command -v "$t" >/dev/null 2>&1 || stop "$t not on PATH"; done
  SHA256="$(sha256_tool)"
  # internal tracker ids never ship (RELEASING.md "Before the tag")
  for f in "$RELEASE_NOTES" "$GATE_REPORT"; do
    if grep -nE '\b(TM|HL)-[0-9]{4}\b' "$f"; then stop "$f carries an internal tracker id (above); strip it"; fi
  done
  grep -q '<<' "$GATE_REPORT" && stop "$GATE_REPORT still has an unfilled <<placeholder>>"
  return 0
}

g() { git -C "$REPO" "$@"; }

# gh JSON without jq: print FIELD of each object (array or single) on stdin
jfield() {
  python3 -I -c '
import json, sys
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else [d]
for r in rows:
    v = r
    for k in sys.argv[1].split("."):
        v = v.get(k) if isinstance(v, dict) else None
    print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))
' "$1"
}

# run_of WORKFLOW: "status conclusion event url" of the newest run of that workflow in $RUNS, or nothing
run_of() {
  printf '%s' "$RUNS" | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    if r["name"] == sys.argv[1]:
        print("%s %s %s %s" % (r["status"], r["conclusion"] or "-", r["event"], r["url"])); break
' "$1"
}

# remote_tag_sha: the commit origin's TAG points at (peeled), or nothing
remote_tag_sha() {
  g ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}" \
    | awk '/\^\{\}$/ {p=$1} !/\^\{\}$/ {t=$1} END {if (p) print p; else if (t) print t}'
}

forbidden_hit() { # path -> 0 if a FORBIDDEN pattern matches
  fh_p="$1"
  for fh_pat in "${FORBIDDEN[@]}"; do
    fh_glob="${fh_pat//\*\*/*}"            # docs/**/verify.md -> docs/*/verify.md (case * crosses /)
    fh_flat="${fh_pat//\/\*\*\//\/}"        # ... and docs/verify.md at depth zero
    # shellcheck disable=SC2254
    case "$fh_p" in $fh_glob|$fh_flat) return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------- 1. verify
verify() {
  say "1/7 verify"
  say "  fetch (reads only): git -C $REPO fetch origin --prune --tags"
  g fetch -q origin --prune --tags
  SHA=$(g rev-parse --verify --quiet "refs/remotes/origin/$TRAIN_BRANCH^{commit}") \
    || stop "origin has no branch $TRAIN_BRANCH"
  say "  train head, from this machine's git: $SHA (origin/$TRAIN_BRANCH)"

  WITNESS_SHA=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("head_sha",""))' "$WITNESS") \
    || stop "cannot read $WITNESS as JSON"
  [ "$WITNESS_SHA" = "$SHA" ] \
    || stop "witness mismatch: $WITNESS says head_sha=${WITNESS_SHA:-<none>}, origin/$TRAIN_BRANCH is $SHA. The lab tested something else; nothing here is signed for that."
  say "  witness agrees: $WITNESS head_sha=$WITNESS_SHA"

  REL_SHA=$(g rev-parse --verify --quiet "refs/remotes/origin/$REL_BRANCH^{commit}") \
    || stop "origin has no branch $REL_BRANCH"
  if [ "$REL_SHA" = "$SHA" ]; then
    say "  origin/$REL_BRANCH is already at the SHA (an earlier run fast-forwarded it)"
  else
    g merge-base --is-ancestor "$REL_SHA" "$SHA" \
      || stop "origin/$REL_BRANCH ($REL_SHA) is not an ancestor of $SHA: not fast-forwardable. Something landed on $REL_BRANCH after the train started; rebuild the candidate."
    say "  origin/$REL_BRANCH $REL_SHA is an ancestor: fast-forward of $(g rev-list --count "$REL_SHA..$SHA") commit(s)"
  fi

  hits=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if forbidden_hit "$f"; then hits="$hits
    $f"; fi
  done <<EOF
$(g diff --name-only "$REL_SHA" "$SHA")
EOF
  [ -z "$hits" ] || stop "the candidate touches a path a train may not change:$hits
  (FORBIDDEN in $SELF). This is not a patch; it needs a reviewed PR, not a morning signature."
  say "  diff $REL_BRANCH..SHA touches none of: ${FORBIDDEN[*]}"

  # the tag: absent, or already on this SHA (resumable)
  TAG_DONE=0
  remote_tag=$(remote_tag_sha) || stop "git ls-remote origin failed"
  if [ -n "$remote_tag" ]; then
    [ "$remote_tag" = "$SHA" ] || stop "tag $TAG already exists on origin at $remote_tag, not $SHA. A tag never moves; this is a different release."
    TAG_DONE=1
  fi
  local_tag=$(g rev-parse --verify --quiet "refs/tags/$TAG^{commit}" || true)
  if [ -n "$local_tag" ]; then
    [ "$local_tag" = "$SHA" ] || stop "tag $TAG exists in $REPO at $local_tag, not $SHA. Delete it only once you know why it is there."
  fi
  if [ "$TAG_DONE" = 1 ]; then say "  tag $TAG already on origin at the SHA (an earlier run pushed it)"
  else say "  tag $TAG does not exist on origin yet"; fi

  # the key is the one .gitsigners (at the SHA) vouches for, before anything is signed
  SIGNERS="$(mktemp)"; trap 'rm -f "$SIGNERS"' EXIT
  g show "$SHA:.gitsigners" > "$SIGNERS" || stop "no .gitsigners at $SHA"
  diff <(ssh-keygen -y -f "$SIGNING_KEY" | awk '{print $1" "$2}') <(awk '{print $2" "$3}' "$SIGNERS") >/dev/null \
    || stop "SIGNING_KEY $SIGNING_KEY is not the key .gitsigners vouches for at $SHA. Signing with it would produce signatures that verify against nothing."
  PRINCIPAL=$(awk 'NR==1{print $1}' "$SIGNERS")
  say "  key matches .gitsigners (principal $PRINCIPAL)"

  # required workflows green on that exact SHA
  RUNS=$(gh run list --repo "$GH_REPO" --commit "$SHA" --limit 100 --json name,status,conclusion,event,url) \
    || stop "gh run list failed for $SHA"
  for w in $REQUIRED; do
    line=$(run_of "$w")
    [ -n "$line" ] || stop "no $w run on $SHA (REQUIRED). The train did not open its PR, or the runs are on another commit."
    # shellcheck disable=SC2086
    set -- $line
    { [ "$1" = completed ] && [ "$2" = success ]; } || stop "$w on $SHA is $1/$2: $4"
    say "  $w: success on $SHA ($3 event) $4"
  done
  for w in $OPTIONAL; do
    line=$(run_of "$w")
    [ -n "$line" ] || { say "  $w: did not run on $SHA (optional, path-filtered)"; continue; }
    # shellcheck disable=SC2086
    set -- $line
    { [ "$1" = completed ] && [ "$2" = success ]; } || stop "$w ran on $SHA and is $1/$2: $4"
    say "  $w: success on $SHA ($3 event) $4"
  done
  say "  VERIFIED $SHA"
}

# ---------------------------------------------------------------- 2. template re-pin
merge_template_pin() {
  say "2/7 merge the $TEMPLATE_REPO re-pin PR #$TEMPLATE_PIN_PR"
  pr=$(gh pr view "$TEMPLATE_PIN_PR" --repo "$TEMPLATE_REPO" --json state,headRefOid,baseRefName,title) \
    || stop "gh pr view $TEMPLATE_PIN_PR --repo $TEMPLATE_REPO failed"
  state=$(printf '%s' "$pr" | jfield state); head=$(printf '%s' "$pr" | jfield headRefOid)
  base=$(printf '%s' "$pr" | jfield baseRefName); title=$(printf '%s' "$pr" | jfield title)
  say "  PR #$TEMPLATE_PIN_PR \"$title\" is $state (head ${head:0:12} -> $base)"
  case "$state" in
    MERGED) say "  already merged; skipping the merge" ;;
    OPEN)
      [ "$base" = main ] || stop "PR #$TEMPLATE_PIN_PR targets $base, not main"
      # the PR's own README must pin TAG: a wrong PR number must not merge anything
      readme=$(gh api "repos/$TEMPLATE_REPO/contents/README.md?ref=$head" --jq .content \
        | python3 -I -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())') \
        || stop "cannot read README.md at the PR head"
      printf '%s\n' "$readme" | grep -q "Pinned to \*\*${TAG}\*\*" \
        || stop "PR #$TEMPLATE_PIN_PR does not pin $TAG (README has: $(printf '%s\n' "$readme" | grep -m1 'Pinned to' || echo '<no Pinned to line>'))"
      say "  PR head pins $TAG"
      gh pr checks "$TEMPLATE_PIN_PR" --repo "$TEMPLATE_REPO" >/dev/null 2>&1 \
        || stop "PR #$TEMPLATE_PIN_PR has a check that is not green (gh pr checks $TEMPLATE_PIN_PR --repo $TEMPLATE_REPO)"
      act "gh pr merge $TEMPLATE_PIN_PR --repo $TEMPLATE_REPO --merge --match-head-commit $head"
      if [ "$GO" = 1 ]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          state=$(gh pr view "$TEMPLATE_PIN_PR" --repo "$TEMPLATE_REPO" --json state | jfield state)
          [ "$state" = MERGED ] && break; sleep 3
        done
        [ "$state" = MERGED ] || stop "PR #$TEMPLATE_PIN_PR did not report MERGED"
        say "  merged; the re-pin window is open until the tag is pushed (RELEASING.md)"
      fi ;;
    *) stop "PR #$TEMPLATE_PIN_PR is $state; a closed re-pin cannot be merged" ;;
  esac
  # the alarm release-tag.yaml will raise, run here first: the template's main must pin TAG
  if [ "$state" = MERGED ]; then
    tdir=$(mktemp -d)
    turl="${SITE_TEMPLATE_URL:-https://github.com/$TEMPLATE_REPO.git}"
    git clone --quiet --depth 1 "$turl" "$tdir" 2>/dev/null || stop "could not clone $turl"
    tool=$(mktemp); g show "$SHA:tools/site-pin-at-tag.sh" > "$tool" || stop "no tools/site-pin-at-tag.sh at $SHA"
    bash "$tool" "$TAG" --dir "$tdir" | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" = 0 ] || stop "the template's main does not pin $TAG after the merge"
    rm -rf "$tdir" "$tool"
  else
    say "  after the merge: tools/site-pin-at-tag.sh $TAG --dir <fresh clone of $TEMPLATE_REPO>"
  fi
}

# ---------------------------------------------------------------- 3. fast-forward
fast_forward() {
  say "3/7 fast-forward $REL_BRANCH to the SHA"
  if [ "$REL_SHA" = "$SHA" ]; then say "  already there; skipping"; return 0; fi
  act "git -C $(q "$REPO") push origin $SHA:refs/heads/$REL_BRANCH"
  if [ "$GO" = 1 ]; then
    g fetch -q origin "$REL_BRANCH"
    [ "$(g rev-parse "refs/remotes/origin/$REL_BRANCH")" = "$SHA" ] || stop "origin/$REL_BRANCH is not at $SHA after the push"
    REL_SHA="$SHA"; say "  origin/$REL_BRANCH is at $SHA"
  fi
}

# ---------------------------------------------------------------- 4. tag
verify_tag() { g -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-tag "$TAG"; }
tag_and_push() {
  say "4/7 signed tag $TAG on the SHA"
  if [ "$TAG_DONE" = 1 ]; then
    verify_tag >/dev/null 2>&1 || stop "tag $TAG is on origin but does not verify against .gitsigners"
    say "  already on origin and verified; skipping"; return 0
  fi
  if [ -n "$(g rev-parse --verify --quiet "refs/tags/$TAG" || true)" ]; then
    say "  local tag exists on the SHA (an earlier run stopped before the push)"
  else
    act "git -C $(q "$REPO") -c gpg.format=ssh -c user.signingkey=$(q "$SIGNING_KEY") tag -s $TAG -m $(q "Tockmox $VER") $SHA"
  fi
  if [ "$GO" = 1 ]; then
    verify_tag 2>&1 | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" = 0 ] || stop "git verify-tag $TAG failed against .gitsigners; the tag is NOT pushed"
  else
    say "  then: git -C $REPO verify-tag $TAG (against .gitsigners at the SHA) before the push"
  fi
  act "git -C $(q "$REPO") push origin refs/tags/$TAG"
  if [ "$GO" = 1 ]; then
    got=$(remote_tag_sha)
    [ "$got" = "$SHA" ] || stop "origin's $TAG points at '$got', not $SHA"
    TAG_DONE=1; say "  $TAG on origin at $SHA, signature verified"
  fi
}

# ---------------------------------------------------------------- 5. sign the report, checksums
sign_and_sum() {
  say "5/7 sign the gate report, archive and SHA256SUMS"
  grep -q "${SHA:0:12}" "$GATE_REPORT" || stop "$GATE_REPORT does not name $SHA; a report that names another commit must not be signed for this one"
  if [ -f "$GATE_REPORT.sig" ]; then
    ssh-keygen -Y verify -f "$SIGNERS" -I "$PRINCIPAL" -n file -s "$GATE_REPORT.sig" < "$GATE_REPORT" >/dev/null 2>&1 \
      || stop "$GATE_REPORT.sig exists and does not verify; move it aside (never overwrite a signature silently)"
    say "  $GATE_REPORT.sig already verifies; skipping"
  else
    act "ssh-keygen -Y sign -f $(q "$SIGNING_KEY") -n file $(q "$GATE_REPORT")"
    if [ "$GO" = 1 ]; then
      ssh-keygen -Y verify -f "$SIGNERS" -I "$PRINCIPAL" -n file -s "$GATE_REPORT.sig" < "$GATE_REPORT" >/dev/null \
        || stop "the fresh $GATE_REPORT.sig does not verify"
      say "  signed and verified (namespace file, principal $PRINCIPAL)"
    fi
  fi
  if [ -f "$ARCHIVE" ] && [ -f "$DIST_DIR/SHA256SUMS" ] && (cd "$DIST_DIR" && $SHA256 -c SHA256SUMS >/dev/null 2>&1); then
    say "  $ARCHIVE and SHA256SUMS already present and verified; skipping"
    return 0
  fi
  # RELEASING.md "Checksums": git archive from the tag, deterministic for a given git
  act "mkdir -p $(q "$DIST_DIR") && git -C $(q "$REPO") archive --format=tar.gz --prefix=tockmox-${VER}/ -o $(q "$ARCHIVE") $TAG"
  act "(cd $(q "$DIST_DIR") && $SHA256 tockmox-${VER}.tar.gz > SHA256SUMS)"
  if [ "$GO" = 1 ]; then
    (cd "$DIST_DIR" && $SHA256 -c SHA256SUMS >/dev/null) || stop "SHA256SUMS does not verify"
    say "  $(cat "$DIST_DIR/SHA256SUMS")"
  fi
}

# ---------------------------------------------------------------- 6. the Release
publish() {
  say "6/7 GitHub Release $TAG (--verify-tag; attachments per RELEASING.md)"
  ASSETS=("$ARCHIVE" "$DIST_DIR/SHA256SUMS" "$GATE_REPORT" "$GATE_REPORT.sig")
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    names=$(gh release view "$TAG" --repo "$GH_REPO" --json assets \
      | python3 -I -c 'import json,sys; print("\n".join(a["name"] for a in json.load(sys.stdin)["assets"]))')
    missing=""
    for a in "${ASSETS[@]}"; do printf '%s\n' "$names" | grep -qx "$(basename "$a")" || missing="$missing $(q "$a")"; done
    if [ -z "$missing" ]; then say "  Release exists with every asset; skipping"; return 0; fi
    say "  Release exists; uploading what it lacks:$missing"
    act "gh release upload $TAG --repo $GH_REPO$missing"
    return 0
  fi
  extra=""; [ -z "$ANNOUNCE" ] || extra=" --discussion-category $(q "$ANNOUNCE")"
  files=""; for a in "${ASSETS[@]}"; do files="$files $(q "$a")"; done
  act "gh release create $TAG --repo $GH_REPO --title $(q "Tockmox $VER") --notes-file $(q "$RELEASE_NOTES") --verify-tag$extra$files"
  if [ "$GO" = 1 ]; then
    gh release view "$TAG" --repo "$GH_REPO" >/dev/null || stop "gh release view $TAG fails after create"
    say "  published: $(gh release view "$TAG" --repo "$GH_REPO" --json url | jfield url)"
  fi
}

# ---------------------------------------------------------------- 7. the log line
log_line() {
  MINS=$(( ( $(date +%s) - T0 + 59 ) / 60 ))
  mode=report; [ "$GO" = 1 ] && mode=go
  line="$(date '+%Y-%m-%d %H:%M') $TAG $SHA $mode ${MINS}min ${ACTIONS}actions"
  say "7/7 log: $line"
  if [ "$GO" = 1 ]; then printf '%s\n' "$line" >> "$TRAIN_LOG"; say "  appended to $TRAIN_LOG"
  else say "  would append to $TRAIN_LOG"; fi
}

run_main() {
  GO=0; ACTIONS=0; T0=$(date +%s)
  SPEC_ARG=""
  for a in "$@"; do
    case "$a" in
      --go) GO=1 ;;
      -h|--help) usage ;;
      --*) stop "unknown option $a" ;;
      *) SPEC_ARG="$a" ;;
    esac
  done
  [ -n "$SPEC_ARG" ] || usage
  load_spec "$SPEC_ARG"
  if [ "$GO" = 1 ]; then say "MODE: --go. Every command below runs."
  else say "MODE: report only. Checks run; every mutation is printed as 'would run' and skipped. Add --go to execute."; fi
  verify
  merge_template_pin
  fast_forward
  tag_and_push
  sign_and_sum
  publish
  log_line
  if [ "$GO" = 1 ]; then say "DONE. $TAG is cut: $ACTIONS actions in $MINS min."
  else say "REPORT DONE: $ACTIONS actions would run. Nothing was changed."; fi
}

# ---------------------------------------------------------------- selftest
# Throwaway repos under /tmp/pt-morning. No network: `gh` is stubbed with an exported
# shell function (gh_stub, below) that answers exactly the calls this script makes,
# and SITE_TEMPLATE_URL points the template clone at a local bare repo. The selftest
# says so on its first line. git, ssh-keygen, python3 and the checksum tool are real.
PT="/tmp/pt-morning"

gh_stub() {  # state lives in $PT_STATE (the fixture directory)
  case "$1 $2" in
    "run list")
      printf '[{"name":"ci","status":"completed","conclusion":"success","event":"pull_request","url":"stub://ci"},'
      printf '{"name":"policy-gate","status":"completed","conclusion":"success","event":"pull_request","url":"stub://policy-gate"}]\n' ;;
    "pr view")
      st=$(cat "$PT_STATE/pr-state"); hd=$(git -C "$PT_STATE/template.git" rev-parse refs/heads/pin)
      printf '{"state":"%s","headRefOid":"%s","baseRefName":"main","title":"Pin to Tockmox v0.8.2"}\n' "$st" "$hd" ;;
    "pr checks") return 0 ;;
    "pr merge")
      echo "merge" >> "$PT_STATE/gh-calls"
      git -C "$PT_STATE/template.git" update-ref refs/heads/main refs/heads/pin
      echo MERGED > "$PT_STATE/pr-state" ;;
    "api repos/"*"/contents/README.md?ref="*)
      ref="${2#*ref=}"
      git -C "$PT_STATE/template.git" show "$ref:README.md" | python3 -I -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode()).decode())' ;;
    "release view")
      [ -f "$PT_STATE/release.json" ] || return 1
      cat "$PT_STATE/release.json" ;;
    "release create")
      echo "release create $*" >> "$PT_STATE/gh-calls"
      names=""; prev=""
      for a in "$@"; do
        case "$prev" in --repo|--title|--notes-file|--discussion-category) prev="$a"; continue ;; esac
        case "$a" in /*) names="$names{\"name\":\"$(basename "$a")\"}," ;; esac
        prev="$a"
      done
      printf '{"url":"stub://release/%s","assets":[%s]}\n' "$3" "${names%,}" > "$PT_STATE/release.json" ;;
    *) echo "gh-stub: unhandled: gh $*" >&2; return 1 ;;
  esac
}

st_commit() { git -C "$1" -c commit.gpgsign=false -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "$2"; }

st_fixture() { # NAME VARIANT -> builds $PT/NAME with origin.git, repo, template.git, spec
  d="$PT/$1"; v="$2"; mkdir -p "$d"
  git init -q --bare "$d/origin.git"; git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
  seed="$d/seed"; git init -q "$seed"; git -C "$seed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$seed/docs/deployment" "$seed/tools"
  printf '%s %s\n' "maintainer@example.com" "$(cut -d' ' -f1,2 < "$PT/key.pub")" > "$seed/.gitsigners"
  echo "security" > "$seed/SECURITY.md"; echo "verify" > "$seed/docs/deployment/verify.md"
  echo "# changelog" > "$seed/CHANGELOG.md"
  # a stand-in for tools/site-pin-at-tag.sh with the same interface (TAG --dir DIR)
  cat > "$seed/tools/site-pin-at-tag.sh" <<'EOS'
#!/usr/bin/env bash
t="$1"; d="$3"; grep -q "Pinned to \*\*$t\*\*" "$d/README.md" && echo "site-pin stand-in: OK, the template pins $t" || { echo "site-pin stand-in: not pinned to $t"; exit 1; }
EOS
  git -C "$seed" add -A; st_commit "$seed" "A: base"
  git -C "$seed" branch -q release-0.8
  git -C "$seed" checkout -q -b train/0.8.2
  echo "- fix" >> "$seed/CHANGELOG.md"
  [ "$v" = forbidden ] && echo "changed" >> "$seed/docs/deployment/verify.md"
  git -C "$seed" add -A; st_commit "$seed" "B: the candidate"
  B=$(git -C "$seed" rev-parse HEAD)
  if [ "$v" = nonff ]; then
    git -C "$seed" checkout -q release-0.8; echo "hotfix" > "$seed/HOTFIX"; git -C "$seed" add -A; st_commit "$seed" "C: landed on release after the train"
  fi
  if [ "$v" = tagexists ]; then git -C "$seed" -c tag.gpgSign=false tag v0.8.2 release-0.8; fi
  git -C "$seed" push -q "$d/origin.git" refs/heads/main refs/heads/release-0.8 refs/heads/train/0.8.2 'refs/tags/*'
  git clone -q "$d/origin.git" "$d/repo"
  git -C "$d/repo" config user.name "selftest"; git -C "$d/repo" config user.email "maintainer@example.com"
  # the site template: main pins the previous release, branch pin pins TAG
  tseed="$d/tseed"; git init -q "$tseed"; git -C "$tseed" symbolic-ref HEAD refs/heads/main
  mkdir -p "$tseed/bootstrap/applications"
  printf 'spec:\n  sources:\n  - targetRevision: v0.8.1\n' > "$tseed/bootstrap/applications/a.yaml"
  printf '# Site\n\nPinned to **v0.8.1**.\n' > "$tseed/README.md"
  git -C "$tseed" add -A; st_commit "$tseed" "pin v0.8.1"
  git -C "$tseed" checkout -q -b pin
  printf 'spec:\n  sources:\n  - targetRevision: v0.8.2\n' > "$tseed/bootstrap/applications/a.yaml"
  printf '# Site\n\nPinned to **v0.8.2**.\n' > "$tseed/README.md"
  git -C "$tseed" add -A; st_commit "$tseed" "pin v0.8.2"
  git init -q --bare "$d/template.git"; git -C "$d/template.git" symbolic-ref HEAD refs/heads/main
  git -C "$tseed" push -q "$d/template.git" refs/heads/main refs/heads/pin
  echo OPEN > "$d/pr-state"
  wsha="$B"; [ "$v" = witness ] && wsha="0000000000000000000000000000000000000000"
  printf '{"run_id":"selftest","head_sha":"%s","outcome":"READY"}\n' "$wsha" > "$d/run.json"
  printf '# Gate report v0.8.2\n\nCommit %s.\n\nWhat was NOT tested: everything, this is a selftest.\n' "$B" > "$d/GATE-REPORT-v0.8.2.md"
  printf 'Release notes for the selftest.\n' > "$d/notes.md"
  cat > "$d/spec" <<EOF
REPO="$d/repo"
GH_REPO="example/tockmox"
TEMPLATE_REPO="example/tockmox-site-template"
REL_BRANCH="release-0.8"
TRAIN_BRANCH="train/0.8.2"
TAG="v0.8.2"
WITNESS="$d/run.json"
TEMPLATE_PIN_PR="7"
GATE_REPORT="$d/GATE-REPORT-v0.8.2.md"
SIGNING_KEY="$PT/key"
RELEASE_NOTES="$d/notes.md"
DIST_DIR="$d/dist"
TRAIN_LOG="$d/train-log.txt"
EOF
}

st_run() { # NAME [--go] -> runs the script on $PT/NAME/spec; output in $PT/NAME/out, rc in $PT/NAME/rc
  d="$PT/$1"; shift
  rc=0
  PT_STATE="$d" SITE_TEMPLATE_URL="$d/template.git" bash "$SELF" "$d/spec" "$@" > "$d/out" 2>&1 || rc=$?
  echo "$rc" > "$d/rc"
}

st_probe() { # LABEL NAME WANT-RC GREP-PATTERN
  st_rc=$(cat "$PT/$2/rc")
  if [ "$st_rc" = "$3" ] && grep -q -- "$4" "$PT/$2/out"; then
    echo "  ok  $1: exit $st_rc, output has '$4'"
  else
    echo "  SELFTEST FAIL: $1 wanted exit $3 with '$4', got exit $st_rc"; sed 's/^/        /' "$PT/$2/out" | tail -15; FAILS=1
  fi
}

st_assert() { # LABEL COMMAND...
  st_l="$1"; shift
  if "$@"; then echo "  ok  $st_l"; else echo "  SELFTEST FAIL: $st_l"; FAILS=1; fi
}

selftest_main() {
  FAILS=0
  echo "selftest: train-morning in $PT (gh is a stubbed shell function, no network; git, ssh-keygen, python3 are real)"
  rm -rf "$PT"; mkdir -p "$PT/tmp"
  export TMPDIR="$PT/tmp"   # hermetic: every mktemp of the runs under test lands here
  ssh-keygen -q -t ed25519 -N '' -C maintainer@example.com -f "$PT/key"
  # shellcheck disable=SC2329  # invoked by the child script through the exported function
  gh() { gh_stub "$@"; }
  export -f gh

  echo "selftest: refusals"
  st_fixture witness witness;     st_run witness;     st_probe "witness head_sha differs from origin/train" witness 1 "witness mismatch"
  st_fixture nonff nonff;         st_run nonff;       st_probe "release branch moved past the train (not fast-forwardable)" nonff 1 "not fast-forwardable"
  st_fixture forbidden forbidden; st_run forbidden;   st_probe "candidate touches docs/deployment/verify.md" forbidden 1 "may not change"
  st_fixture tagexists tagexists; st_run tagexists;   st_probe "tag v0.8.2 already on origin at another commit" tagexists 1 "already exists on origin"
  st_fixture wrongkey good; ssh-keygen -q -t ed25519 -N '' -f "$PT/otherkey"
  sed -i.bak "s|SIGNING_KEY=.*|SIGNING_KEY=\"$PT/otherkey\"|" "$PT/wrongkey/spec"; st_run wrongkey
  st_probe "signing key is not the .gitsigners key" wrongkey 1 "not the key .gitsigners vouches for"
  for n in witness nonff forbidden tagexists wrongkey; do
    st_assert "$n: nothing merged, pushed or signed" bash -c "[ ! -f $PT/$n/gh-calls ] && [ \"\$(cat $PT/$n/pr-state)\" = OPEN ] && [ ! -f $PT/$n/GATE-REPORT-v0.8.2.md.sig ]"
  done

  echo "selftest: report-only prints without acting"
  st_fixture good good; A=$(git -C "$PT/good/origin.git" rev-parse refs/heads/release-0.8); B=$(git -C "$PT/good/origin.git" rev-parse refs/heads/train/0.8.2)
  st_run good
  st_probe "report-only exits 0" good 0 "REPORT DONE: 8 actions would run"
  st_probe "it prints the fast-forward push" good 0 "would run: \$ git -C .*push origin $B:refs/heads/release-0.8"
  st_probe "it prints the signed tag" good 0 "would run: .*tag -s v0.8.2"
  st_probe "it prints the release with --verify-tag" good 0 "would run: \$ gh release create v0.8.2 .*--verify-tag"
  st_assert "origin/release-0.8 untouched" test "$(git -C "$PT/good/origin.git" rev-parse refs/heads/release-0.8)" = "$A"
  st_assert "no tag on origin" bash -c "! git -C $PT/good/origin.git rev-parse -q --verify refs/tags/v0.8.2 >/dev/null"
  st_assert "template PR not merged" test "$(cat "$PT/good/pr-state")" = OPEN
  st_assert "no .sig, no dist, no log line" bash -c "[ ! -f $PT/good/GATE-REPORT-v0.8.2.md.sig ] && [ ! -d $PT/good/dist ] && [ ! -f $PT/good/train-log.txt ]"

  echo "selftest: --go against the throwaway origin (gh stubbed), then a second --go that skips everything"
  st_run good --go
  st_probe "--go exits 0" good 0 "DONE. v0.8.2 is cut: 8 actions"
  st_assert "origin/release-0.8 fast-forwarded to the candidate" test "$(git -C "$PT/good/origin.git" rev-parse refs/heads/release-0.8)" = "$B"
  st_assert "tag v0.8.2 on origin at the candidate" test "$(git -C "$PT/good/origin.git" rev-parse 'refs/tags/v0.8.2^{commit}')" = "$B"
  st_assert "tag verifies against .gitsigners" bash -c "git -C $PT/good/repo -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=$PT/good/repo/.gitsigners verify-tag v0.8.2 >/dev/null 2>&1"
  st_assert "template PR merged and template main pins v0.8.2" bash -c "[ \"\$(cat $PT/good/pr-state)\" = MERGED ] && git -C $PT/good/template.git show main:README.md | grep -q 'Pinned to \*\*v0.8.2\*\*'"
  st_assert "gate report signature verifies (namespace file)" bash -c "ssh-keygen -Y verify -f $PT/good/repo/.gitsigners -I maintainer@example.com -n file -s $PT/good/GATE-REPORT-v0.8.2.md.sig < $PT/good/GATE-REPORT-v0.8.2.md >/dev/null 2>&1"
  st_assert "SHA256SUMS verifies the archive" bash -c "cd $PT/good/dist && $(sha256_tool) -c SHA256SUMS >/dev/null 2>&1 && tar tzf tockmox-0.8.2.tar.gz | grep -q '^tockmox-0.8.2/CHANGELOG.md'"
  st_assert "release created with --verify-tag and the four attachments" bash -c "grep -q -- '--verify-tag' $PT/good/gh-calls && python3 -I -c 'import json,sys; a=sorted(x[\"name\"] for x in json.load(open(sys.argv[1]))[\"assets\"]); sys.exit(0 if a==[\"GATE-REPORT-v0.8.2.md\",\"GATE-REPORT-v0.8.2.md.sig\",\"SHA256SUMS\",\"tockmox-0.8.2.tar.gz\"] else 1)' $PT/good/release.json"
  st_assert "order: merge first, release last" bash -c "[ \"\$(sed -n 1p $PT/good/gh-calls)\" = merge ] && [ \"\$(tail -1 $PT/good/gh-calls | cut -c1-14)\" = 'release create' ]"
  st_assert "one log line with minutes and the action count" bash -c "[ \$(wc -l < $PT/good/train-log.txt) -eq 1 ] && grep -q ' go [0-9]*min 8actions' $PT/good/train-log.txt"
  st_run good --go
  st_probe "second --go skips every step" good 0 "DONE. v0.8.2 is cut: 0 actions"
  st_assert "second run appended its own log line" test "$(wc -l < "$PT/good/train-log.txt")" -eq 2

  if [ "$FAILS" = 0 ]; then echo "train-morning --selftest: PASSED"; exit 0; fi
  echo "train-morning --selftest: FAILED"; exit 1
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
  --selftest) selftest_main ;;
  "") usage ;;
  *) run_main "$@" ;;
esac

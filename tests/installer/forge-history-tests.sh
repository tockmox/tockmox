#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Sourced by run.sh. Groups H1-H9: install/forge-history.py reads a REAL dump,
# made by install/forge-offsite-copy.sh TASK=dump against lib/forge-stub.py in git mode and
# read back from the pushed forge-dump branch. Each red case mutates a copy of the good dump,
# so each proves its check can go red. H7-H9 restore that dump into the stub forge.

HF="$REPO_ROOT/install/forge-history.py"

# hf_check DIR: the check's output (stdout and stderr) and "rc=<exit>"
hf_check() { python3 "$HF" check "$1" 2>&1; echo "rc=$?"; }
# hf_lines DIR: per PR line: number, title, whether it names the approver and the path
hf_lines() {
  python3 "$HF" issues "$1" | python3 -c '
import json, sys
for l in sys.stdin:
    o = json.loads(l)
    print(o["number"], o["title"], "approver" in o["body"], "a.yaml" in o["body"])'
}

path_begin "H0" "a real dump is made and read back from the remote's forge-dump branch"
dp_start h
dp_run TASK=dump MODE=git GIT_REMOTE_URL="http://127.0.0.1:$DP_PORT/remote/site.git"
HG="$D/good"; mkdir -p "$HG"
(PATH="$DP_PATH" git -C "$D/root/remote/site.git" archive forge-dump dump | tar -x -C "$HG")
HG="$HG/dump"
dp_stop
assert_artifact "the dump job exited 0 and the dump has a manifest" \
  "echo $DP_STATUS; test -f '$HG/MANIFEST' && echo yes || echo no" "$(printf '0\nyes')"

path_begin "H1" "check on a real dump prints the counts line and exits 0"
assert_artifact "the counts line and rc=0" \
  "hf_check '$HG' | sed 's/^dump [0-9TZ]* /dump /'" \
  "$(printf 'dump of tockmox/site: 3 pull requests, 3 reviews, 3 review comments, 3 issue comments\nrc=0')"

path_begin "H2" "issues emits one line per PR, ascending, naming reviewers and paths"
assert_artifact "three lines, titles Restored: #n, approver and a.yaml in each body" \
  "hf_lines '$HG'" \
  "$(printf '1 Restored: #1 change 1 True True\n2 Restored: #2 change 2 True True\n3 Restored: #3 change 3 True True')"

path_begin "H3" "a changed pull-requests count in the MANIFEST makes check exit 1 naming the count"
cp -R "$HG" "$D/m3"
sed 's/^pull-requests 3/pull-requests 4/' "$HG/MANIFEST" > "$D/m3/MANIFEST"
assert_artifact "exit 1 and the message names pull-requests" \
  "hf_check '$D/m3' | sed -n '/pull-requests/p;/^rc=/p' | tr '\n' '|'" \
  "forge-history: MANIFEST says pull-requests 4, but 3 were read|rc=1|"

path_begin "H4" "a v2 MANIFEST first line makes check exit 1"
cp -R "$HG" "$D/m4"
sed '1s/.*/format tockmox-forge-dump v2/' "$HG/MANIFEST" > "$D/m4/MANIFEST"
assert_artifact "exit 1 and the message names the v1 format" \
  "hf_check '$D/m4' | grep -E 'v1|^rc=' | tr '\n' '|'" \
  'forge-history: MANIFEST first line is not "format tockmox-forge-dump v1"|rc=1|'

path_begin "H5" "a truncated review-comments file makes check exit 1"
cp -R "$HG" "$D/m5"
head -c 20 "$HG/review-comments-1-10.json" > "$D/m5/review-comments-1-10.json"
assert_artifact "exit 1 and the message names the file" \
  "hf_check '$D/m5' | sed -n 's/^\(forge-history: review-comments-1-10.json\).*/\1/p;/^rc=/p' | tr '\n' '|'" \
  "forge-history: review-comments-1-10.json|rc=1|"

path_begin "H6" "a 70000-character PR body is cut with the note"
cp -R "$HG" "$D/m6"
python3 - "$D/m6/pulls-1.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d[0]["body"] = "x" * 70000
json.dump(d, open(p, "w"))
PYEOF
hf_cut() {
  python3 "$HF" issues "$D/m6" | head -n 1 | python3 -c '
import json, sys
b = json.loads(sys.stdin.readline())["body"]
print("x" * 60000 in b, "x" * 60001 in b, ("x" * 60000 + "\n\n_(cut: the full text is in the forge dump)_\n") in b)'
}
assert_artifact "60000 kept, not 60001, and the note follows the cut description" \
  "hf_cut" "True False True"

# hf_restore: restore the good dump into the running stub; prints its summary line and rc
hf_restore() { printf 'admin:pw\n' | python3 "$HF" restore "$HG" --api "http://127.0.0.1:$DP_PORT/api/v1" --repo tockmox/site 2>&1; echo "rc=$?"; }
# hf_issues: what the stub now holds: per issue, its number, state, label and title
hf_issues() {
  python3 -c '
import json, sys
st = json.load(open(sys.argv[1]))
for i in st["issues"]:
    print(i["number"], i["state"], ",".join(l["name"] for l in i["labels"]), i["title"])' "$D/root/issues.json"
}

path_begin "H7" "restore posts one closed issue per pull request, labelled restored-from-dump"
dp_start h7
assert_artifact "the summary names three restored and none failed" \
  "hf_restore | sed 's/ from the forge dump of .*//'" \
  "$(printf '3 pull requests restored as closed issues (0 already present, 0 failed)\nrc=0')"
assert_artifact "the forge holds three closed, labelled issues" \
  "hf_issues" \
  "$(printf '1 closed restored-from-dump Restored: #1 change 1\n2 closed restored-from-dump Restored: #2 change 2\n3 closed restored-from-dump Restored: #3 change 3')"

path_begin "H8" "a second restore creates nothing twice"
assert_artifact "the summary names three already present" \
  "hf_restore | sed 's/ from the forge dump of .*//'" \
  "$(printf '0 pull requests restored as closed issues (3 already present, 0 failed)\nrc=0')"
assert_artifact "still three issues on the forge" "hf_issues | wc -l | tr -d ' '" "3"

path_begin "H9" "restore refuses a credential that is not user:password on stdin"
assert_artifact "exit 2 and the message says where the credential goes" \
  "printf 'nocolon\n' | python3 '$HF' restore '$HG' --api 'http://127.0.0.1:$DP_PORT/api/v1' --repo tockmox/site 2>&1; echo rc=\$?" \
  "$(printf 'forge-history: restore reads user:password from the first line of stdin\nrc=2')"
dp_stop

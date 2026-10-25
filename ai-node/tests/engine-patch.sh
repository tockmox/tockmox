#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tests of bin/tockmox-ai-node-engine-patch against a fake virtual environment (a pip that reinstalls a
# pristine fixture package, a python that names the site-packages and byte-compiles with the real
# python3) and the real patch(1): nothing wanted and nothing recorded changes nothing; a named patch is
# applied once to a clean reinstall and recorded; a second run, a new patch body, a new version and a
# removed name each do what the header says; a patch that does not apply, or leaves a file that does not
# compile, leaves the clean release and no record; a missing patch or a bad name is refused first.
#
#   ai-node/tests/engine-patch.sh
#
# Plain bash; exit 0 all passed, 1 a failure.
# shellcheck disable=SC2015  # "A && ok || bad" is the harness idiom; ok never fails
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd -P)"
HELPER="$HERE/../bin/tockmox-ai-node-engine-patch"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3], got [$2]"; fi; }

[ -x "$HELPER" ] || { bad "the patch helper is installed in bin/ and executable"; echo "engine-patch: $pass passed, $fail failed"; exit 1; }
command -v patch >/dev/null 2>&1 || { echo "engine-patch: needs patch(1)" >&2; exit 1; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
V="$W/venv"; SITE="$V/lib/site-packages"; PRISTINE="$W/pristine"; P="$W/patches"
mkdir -p "$V/bin" "$SITE" "$PRISTINE/demo" "$P"

cat > "$PRISTINE/demo/core.py" <<'PY'
def step(state):
    # evaluate the tokens
    return state + 1
PY

# pip: install --force-reinstall restores the pristine package; every call is logged; fails on request.
cat > "$V/bin/pip" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$W/pip.log"
[ -e "$W/pip-fail" ] && exit 3
rm -rf "$SITE/demo" && cp -R "$PRISTINE/demo" "$SITE/demo"
SH
# python: names the site-packages for the sysconfig query, byte-compiles with the real python3.
cat > "$V/bin/python" <<SH
#!/bin/bash
case "\$1" in
  -c) printf '%s\n' "$SITE" ;;
  -m) shift; exec python3 -m "\$@" ;;
esac
SH
chmod +x "$V/bin/pip" "$V/bin/python"
cp -R "$PRISTINE/demo" "$SITE/demo"

cat > "$P/eval-state.patch" <<'EOF'
SPDX-License-Identifier: Apache-2.0
A test patch. Text before the first diff header is ignored by patch(1).

--- a/demo/core.py
+++ b/demo/core.py
@@ -1,3 +1,3 @@
 def step(state):
-    # evaluate the tokens
+    # evaluate the tokens and the state
     return state + 1
EOF
cat > "$P/does-not-apply.patch" <<'EOF'
--- a/demo/core.py
+++ b/demo/core.py
@@ -1,3 +1,3 @@
 def step(state):
-    # a line that is not there
+    # replaced
     return state + 1
EOF
cat > "$P/breaks-python.patch" <<'EOF'
--- a/demo/core.py
+++ b/demo/core.py
@@ -1,3 +1,3 @@
 def step(state):
-    # evaluate the tokens
+    return (
     return state + 1
EOF

run() { "$HELPER" --venv "$V" --package demo --version "${VER:-1.0.0}" --patches "${PD:-$P}" "$@" > "$W/out" 2> "$W/err"; echo $?; }
pips() { if [ -f "$W/pip.log" ]; then grep -c . "$W/pip.log"; else echo 0; fi; }
pristine() { cmp -s "$PRISTINE/demo/core.py" "$SITE/demo/core.py" && echo yes || echo no; }
REC="$V/.tockmox-engine-patches"

echo "engine patch"
eq "nothing wanted, nothing recorded: exit 0" "$(run)" 0
eq "  and it says unchanged" "$(cat "$W/out")" "unchanged"
eq "  and pip is not called" "$(pips)" 0

eq "a named patch: exit 0" "$(run eval-state)" 0
grep -q '^changed: demo 1.0.0 with 1 patch(es): eval-state$' "$W/out" && ok "  it says changed and names the patch" || bad "  it says changed and names the patch" "$(cat "$W/out")"
grep -q 'evaluate the tokens and the state' "$SITE/demo/core.py" && ok "  the file is patched" || bad "  the file is patched"
eq "  pip reinstalled the release once" "$(pips)" 1
grep -q -- '--force-reinstall --no-deps demo==1.0.0' "$W/pip.log" && ok "  as a forced reinstall of the pinned version without dependencies" || bad "  forced reinstall" "$(cat "$W/pip.log")"
eq "  the record names the release and the patch" "$(sed -n 1p "$REC") $(awk 'NR==2{print $1}' "$REC")" "demo 1.0.0 eval-state"

eq "the same again: exit 0" "$(run eval-state)" 0
eq "  and it says unchanged" "$(cat "$W/out")" "unchanged"
eq "  and pip is not called again" "$(pips)" 1

printf '\n' >> "$P/eval-state.patch"
eq "a new patch body: exit 0" "$(run eval-state)" 0
eq "  it reinstalls and applies again" "$(pips)" 2
grep -q 'evaluate the tokens and the state' "$SITE/demo/core.py" && ok "  over a clean tree (applied exactly once)" || bad "  applied once"
eq "  never twice" "$(grep -c 'and the state' "$SITE/demo/core.py")" 1

eq "a new version: exit 0" "$(VER=1.0.1 run eval-state)" 0
grep -q -- 'demo==1.0.1' "$W/pip.log" && ok "  it reinstalls the new version" || bad "  it reinstalls the new version"
eq "  the record follows" "$(sed -n 1p "$REC")" "demo 1.0.1"

eq "the name removed: exit 0" "$(VER=1.0.1 run)" 0
eq "  it says the release is back without patches" "$(cat "$W/out")" "changed: demo 1.0.1 reinstalled without patches"
eq "  the file is the release as published" "$(pristine)" yes
[ ! -e "$REC" ] && ok "  and the record is gone" || bad "  and the record is gone"

eq "a patch that does not apply: exit 1" "$(run eval-state does-not-apply)" 1
grep -q 'does-not-apply does not apply' "$W/err" && ok "  the message names the patch" || bad "  the message names the patch" "$(cat "$W/err")"
eq "  the clean release stays" "$(pristine)" yes
[ ! -e "$REC" ] && ok "  and nothing is recorded" || bad "  and nothing is recorded"

eq "a patch that breaks the Python: exit 1" "$(run breaks-python)" 1
grep -q 'breaks-python leaves demo/core.py unable to compile' "$W/err" && ok "  the message names the patch and the file" || bad "  the message names the patch and the file" "$(cat "$W/err")"
eq "  the clean release stays" "$(pristine)" yes

before="$(pips)"
eq "a patch the toolkit does not have: exit 1" "$(run no-such-patch)" 1
grep -q 'no patch named no-such-patch' "$W/err" && ok "  the message names it" || bad "  the message names it" "$(cat "$W/err")"
eq "  before pip is called" "$(pips)" "$before"

eq "a name that is not lower-case letters, digits and dashes: exit 64" "$(run 'Bad_Name')" 64
eq "a name that looks like an option: exit 64" "$(run -- -x)" 64
eq "no arguments: exit 64" "$("$HELPER" > /dev/null 2>&1; echo $?)" 64

touch "$W/pip-fail"
eq "pip fails: exit 1" "$(run eval-state)" 1
rm -f "$W/pip-fail"

( cd "$W" && PD=patches run eval-state > "$W/rc" ); eq "a relative patch directory works (patch -d changes directory)" "$(cat "$W/rc")" 0
grep -q 'evaluate the tokens and the state' "$SITE/demo/core.py" && ok "  and the file is patched" || bad "  and the file is patched"

echo "engine-patch: $pass passed, $fail failed"
[ "$fail" = 0 ]

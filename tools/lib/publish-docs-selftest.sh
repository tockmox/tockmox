#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The self-test behind `tools/publish-docs.sh --selftest` (TM-0807). Runs the
# real script against a STUB kubectl on PATH that records every call, and
# asserts on what the script asked the cluster to do. It needs no cluster, no
# generator and no network.
#
# Every assertion below is also proven able to fail: a block at the end feeds
# each assertion helper a log that violates it and requires it to go red, so a
# helper that has gone vacuous is caught here and not in an incident.
#
# WHAT THIS DOES NOT PROVE. The stub answers what the script expects; it says
# nothing about a real API server, Pod Security admission, the image's tar, or
# Garage. The lab run in the TM-0807 report is where those were observed.
set -uo pipefail
ROOT="${1:?usage: publish-docs-selftest.sh REPO_ROOT}"
cd "$ROOT"
T="$(mktemp -d "${TMPDIR:-/tmp}/publish-docs-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Stub kubectl: log every call, answer just enough for publish-docs.sh.
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$STUB_LOG"
a=("$@"); i=0; verb=""; rest=()
while [ $i -lt ${#a[@]} ]; do
  case "${a[$i]}" in
    --context|-n) i=$((i + 2)); continue ;;
  esac
  if [ -z "$verb" ]; then verb="${a[$i]}"; else rest+=("${a[$i]}"); fi
  i=$((i + 1))
done
case "$verb" in
  get)
    case "${rest[0]:-}" in
      secret) [ "${STUB_NO_SECRET:-0}" = 1 ] && exit 1; echo "secret/${rest[1]:-x}" ;;
      pod) [ -e "$STUB_DIR/deleted" ] || echo "pod/${rest[1]:-x}" ;;
    esac ;;
  create)
    f=""; j=0; while [ $j -lt ${#rest[@]} ]; do [ "${rest[$j]}" = "-f" ] && f="${rest[$((j + 1))]}"; j=$((j + 1)); done
    cp "$f" "$STUB_DIR/pod.yaml"; echo "pod/created" ;;
  wait) exit "${STUB_WAIT_RC:-0}" ;;
  cp) exit 0 ;;
  exec)
    # the script is the argument after "bash -c"
    j=0; while [ $j -lt ${#rest[@]} ]; do [ "${rest[$j]}" = "-c" ] && printf '%s' "${rest[$((j + 1))]}" > "$STUB_DIR/exec-script.txt"; j=$((j + 1)); done
    exit "${STUB_EXEC_RC:-0}" ;;
  delete) : > "$STUB_DIR/deleted"; echo "pod deleted" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/bin/kubectl"

mk_site() {  # dir
  mkdir -p "$1/assets"
  printf '<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="assets/a.css"></head><body><a href="https://example.org/x">x</a></body></html>\n' > "$1/index.html"
  printf 'body{}\n' > "$1/assets/a.css"
}

run() {  # name, then env assignments and args; sets RC and OUT, fresh STUB_DIR
  local name="$1"; shift
  RUN_DIR="$T/run-$name"; mkdir -p "$RUN_DIR"; : > "$RUN_DIR/log"
  OUT="$( env PATH="$T/bin:$PATH" STUB_LOG="$RUN_DIR/log" STUB_DIR="$RUN_DIR" "$@" 2>&1 )"; RC=$?
}
PUB="bash $ROOT/tools/publish-docs.sh"

# ---- assertion helpers (each is proven to fail at the end) --------------------
assert_every_call_names_context() {  # log
  [ -s "$1" ] || return 1
  ! grep -v '^--context selftest-ctx ' "$1" | grep . >/dev/null
}
assert_no_secret_read() {  # log: a secret is only ever asked for by name
  ! grep -E ' secret ' "$1" | grep -v -- '-o name' | grep . >/dev/null
}
assert_pod_deleted_last() {  # log: the last call is the pod removal (or the check after it)
  local last; last="$(grep -v ' get pod ' "$1" | tail -n 1)"
  case "$last" in *" delete pod tockmox-publish-docs-"*) return 0 ;; *) return 1 ;; esac
}
assert_no_create() { ! grep -q ' create -f ' "$1"; }
assert_contains() {  # file, fixed string
  grep -qF -- "$2" "$1"
}

SITE="$T/site"; mk_site "$SITE"
IMG="$(grep -E '^alpine/k8s:' images.txt | head -n 1)"
GOOD=(PUBLISH_DOCS_DESCRIBE=v9.9.9 PUBLISH_DOCS_HEAD=abcdef0123456789abcdef0123456789abcdef01)

echo "-- a publish: what the script asks the cluster to do"
run happy "${GOOD[@]}" $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9
L="$RUN_DIR/log"; P="$RUN_DIR/pod.yaml"; S="$RUN_DIR/exec-script.txt"
[ "$RC" -eq 0 ] && ok "exit 0" || { fail "exit $RC: $OUT"; }
assert_every_call_names_context "$L" && ok "every kubectl call carries --context selftest-ctx" || fail "a kubectl call lacks --context"
assert_no_secret_read "$L" && ok "the writer Secret is only asked for by name (-o name)" || fail "the Secret's data was requested"
assert_pod_deleted_last "$L" && ok "the pod is deleted last" || fail "the pod was not deleted at the end"
for want in 'runAsNonRoot: true' 'runAsUser: 65534' 'readOnlyRootFilesystem: true' 'allowPrivilegeEscalation: false' 'drop: ["ALL"]' \
            'seccompProfile: { type: RuntimeDefault }' 'app.kubernetes.io/part-of: tockmox' 'tockmox.com/managed-by: tockmox' \
            'tockmox.com/layer: platform' 'automountServiceAccountToken: false' "image: $IMG" \
            'secretKeyRef: { name: tockmox-garage-site-docs, key: ACCESS_SECRET_KEY }' 'activeDeadlineSeconds:'; do
  assert_contains "$P" "$want" && ok "pod spec has: $want" || fail "pod spec lacks: $want"
done
assert_contains "$P" '"ref":"v9.9.9"' && ok "the marker names the ref" || fail "marker lacks the ref"
assert_contains "$P" '"commit":"abcdef0123456789abcdef0123456789abcdef01"' && ok "the marker names the commit" || fail "marker lacks the commit"
grep -Eq '"tree_sha256":"[0-9a-f]{64}"' "$P" && ok "the marker carries a sha256 of the tree" || fail "marker lacks tree_sha256"
for want in 'touch' '--delete' 'head-bucket' 'is missing. Refusing to sync' '.tockmox-docs-version' ; do
  assert_contains "$S" "$want" && ok "the in-pod script has: $want" || fail "the in-pod script lacks: $want"
done
grep -q ' cp ' "$L" && ok "kubectl cp copies the site in" || fail "no kubectl cp"
grep -qE 'AWS_SECRET|secret.*jsonpath' "$RUN_DIR/log" && fail "a credential name reached a kubectl argument" || ok "no credential reached a kubectl argument"

echo "-- a failing step still removes the pod"
run execfail "${GOOD[@]}" STUB_EXEC_RC=1 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9
[ "$RC" -ne 0 ] && ok "a failing in-pod step makes the script fail (exit $RC)" || fail "a failing exec exited 0"
assert_pod_deleted_last "$RUN_DIR/log" && ok "the pod was deleted after the failure" || fail "the pod survived a failed publish"
run waitfail "${GOOD[@]}" STUB_WAIT_RC=1 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9
[ "$RC" -ne 0 ] && assert_pod_deleted_last "$RUN_DIR/log" && ok "a pod that never becomes Ready fails and is removed" || fail "a never-Ready pod was not handled"

echo "-- refusals happen before the cluster is touched"
refuse() {  # name, description, expected text, then run args
  local name="$1" what="$2" text="$3"; shift 3
  run "$name" "$@"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -- "$text" >/dev/null && assert_no_create "$RUN_DIR/log"; then ok "$what"; else fail "$what (rc=$RC, out: $(printf '%s' "$OUT" | tail -n 3))"; fi
}
refuse nocontext "no --context is refused with usage (64)" "--context is required" $PUB --site "$SITE"
[ "$RC" -eq 64 ] || fail "no --context exited $RC, want 64"
refuse tagmismatch "a checkout on another tag than tockmox.revision is refused" "REFUSED" env PUBLISH_DOCS_DESCRIBE=v1.0.0 PUBLISH_DOCS_HEAD=abcdef0123456789abcdef0123456789abcdef01 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9
refuse notag "a checkout on no exact tag is refused when a revision is given" "REFUSED" env PUBLISH_DOCS_DESCRIBE= PUBLISH_DOCS_HEAD=abcdef0123456789abcdef0123456789abcdef01 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9
run force env PUBLISH_DOCS_DESCRIBE=v1.0.0 PUBLISH_DOCS_HEAD=abcdef0123456789abcdef0123456789abcdef01 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9 --force
[ "$RC" -eq 0 ] && grep -q ' create -f ' "$RUN_DIR/log" && ok "--force publishes despite the mismatch" || fail "--force did not publish (rc=$RC)"
run sha "${GOOD[@]}" $PUB --context selftest-ctx --site "$SITE" --revision abcdef0
[ "$RC" -eq 0 ] && ok "a revision given as a commit prefix matches HEAD" || fail "a commit-prefix revision was refused (rc=$RC)"
printf 'site:\n  name: x\ntockmox:\n  repoURL: https://example.invalid/t.git\n  revision: v9.9.9   # pinned\n' > "$T/cfg.yaml"
run cfg "${GOOD[@]}" $PUB --context selftest-ctx --site "$SITE" --config "$T/cfg.yaml"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep 'this checkout is v9.9.9' >/dev/null && ok "tockmox.revision is read from --config" || fail "--config revision not honoured (rc=$RC)"
NOIDX="$T/noindex"; mk_site "$NOIDX"; rm -f "$NOIDX/index.html"; printf 'x\n' > "$NOIDX/page.html"
refuse noindex "a site with no index.html is refused" "index.html is missing" env "${GOOD[@]}" $PUB --context selftest-ctx --site "$NOIDX" --revision v9.9.9
EXT="$T/ext"; mk_site "$EXT"; printf '<link rel="stylesheet" href="https://fonts.googleapis.com/css">' >> "$EXT/index.html"
refuse external "a site that fetches from the network is refused" "would fetch from the network" env "${GOOD[@]}" $PUB --context selftest-ctx --site "$EXT" --revision v9.9.9
ELF="$T/elf"; mk_site "$ELF"; printf '\177ELF\002\001\001' > "$ELF/assets/logo.png"
refuse elf "a site holding an ELF renamed .png is refused" "not static web content" env "${GOOD[@]}" $PUB --context selftest-ctx --site "$ELF" --revision v9.9.9
refuse nosecret "a missing writer Secret is refused" "not found in namespace" env "${GOOD[@]}" STUB_NO_SECRET=1 $PUB --context selftest-ctx --site "$SITE" --revision v9.9.9

echo "-- every assertion above can fail"
printf '%s\n' '-n ns get secret x -o name' > "$T/bad1"
assert_every_call_names_context "$T/bad1" && fail "assert_every_call_names_context passed a call with no --context" || ok "a call with no --context turns it red"
printf '%s\n' '--context selftest-ctx -n ns get secret x -o jsonpath={.data}' > "$T/bad2"
assert_no_secret_read "$T/bad2" && fail "assert_no_secret_read passed a Secret data read" || ok "reading a Secret's data turns it red"
printf '%s\n' '--context selftest-ctx -n ns exec tockmox-publish-docs-1 -c publish -- bash -c x' > "$T/bad3"
assert_pod_deleted_last "$T/bad3" && fail "assert_pod_deleted_last passed a log with no delete" || ok "a missing pod delete turns it red"
printf '%s\n' '--context selftest-ctx -n ns create -f /tmp/pod.yaml' > "$T/bad4"
assert_no_create "$T/bad4" && fail "assert_no_create passed a log with a create" || ok "a create call turns it red"
printf 'nothing\n' > "$T/bad5"
assert_contains "$T/bad5" 'runAsNonRoot: true' && fail "assert_contains passed a file without the string" || ok "an absent string turns it red"

if [ "$fails" -eq 0 ]; then echo "SELFTEST PASSED"; exit 0; fi
echo "SELFTEST FAILED ($fails)"; exit 1

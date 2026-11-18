#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# release-feed.sh ... the producer side of the opt-in update check: the signed releases.json the
# console reads (tockmox-ui/app/feed.py) and its detached signature.
#
#   tools/release-feed.sh add FEED --version X.Y.Z --date YYYY-MM-DD [--notes TEXT] [--notes-url URL]
#                                  [--min-upgrade-from X.Y.Z] [--breaking TEXT]... [--security] [--replace]
#                         add one release to FEED (a new FEED starts empty). Unsigned until `sign`.
#   tools/release-feed.sh sign FEED KEY [--pin PUBKEY]...
#                         set signed=now and expires=now+45 days, write FEED and FEED.sig, then verify
#                         the signature with KEY's public half. With --pin, refuse a KEY whose public
#                         half is not one of the pinned keys the chart ships.
#   tools/release-feed.sh verify FEED PUBKEY...
#                         what the console checks: a signature by one of the keys, schema 1, a releases
#                         list, and an expires in the future. Prints the days left.
#   tools/release-feed.sh due FEED|https-URL [--days N]
#                         the re-sign reminder: exit 3 when the feed was signed N days ago or more
#                         (default 30), so a scheduled job can say so before the 45-day expiry.
#                         Exit 0 when it is fresh, 1 when it cannot be read.
#   tools/release-feed.sh pubkey KEY
#                         KEY's public half as the console pins it (base64 of the raw 32 bytes).
#   tools/release-feed.sh --selftest
#                         every refusal, with a throwaway key made in a temporary directory.
#
# FORMAT (the console's contract, tockmox-ui/app/feed.py):
#   {"schema": 1, "signed": <unix s>, "expires": <unix s>, "releases": [{"version": "X.Y.Z",
#    "date": "YYYY-MM-DD", "notes": "...", "notesUrl": "https://...", "minUpgradeFrom": "X.Y.Z",
#    "breaking": ["..."], "security": true}, ...]}
#   FEED.sig is the base64 of the raw Ed25519 signature over FEED's exact bytes.
#
# WHY EXPIRES. An old signed feed can be replayed to hide a newer release; the console refuses an
# expired one. The producer always sets it: 45 days, re-signed on every release and when this
# script's `due` says so.
#
# KEYS. A dedicated offline Ed25519 key signs the feed, not the tag key, with a second key pinned
# beside it from the start so the first can be retired. KEY is a PEM private key in a file this
# script only reads; nothing here makes, copies or prints a private key.
#
# Requires: OpenSSL 3 (`openssl pkeyutl -rawin`; set OPENSSL to its path if `openssl` is LibreSSL),
# python3, base64. For `due` on a URL: curl.
# macOS bash 3.2 clean.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
OPENSSL="${OPENSSL:-openssl}"
EXPIRES_DAYS=45
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

say()  { printf '%s\n' "$*"; }
stop() { echo "STOP: $*" >&2; exit 1; }
usage() { sed -n '7,24p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2; }

need_openssl() {
  command -v "$OPENSSL" >/dev/null 2>&1 || stop "$OPENSSL not found (OpenSSL 3 is needed; set OPENSSL)"
  case "$("$OPENSSL" version 2>/dev/null)" in
    "OpenSSL 3."*) ;;
    *) stop "$OPENSSL is '$("$OPENSSL" version 2>/dev/null)', not OpenSSL 3: it cannot sign Ed25519 raw (install OpenSSL 3 and set OPENSSL to it)" ;;
  esac
}

# the raw 32-byte public key, base64, from a PEM private key
pub_of() {
  "$OPENSSL" pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n'
}

# a PEM public key file from a base64 raw key (the 12-byte Ed25519 SPKI prefix, then the key)
pem_of_raw() { # B64 OUTFILE
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$1" | base64 -d 2>/dev/null; } \
    | "$OPENSSL" pkey -pubin -inform DER -out "$2" 2>/dev/null
}

cmd_add() {
  feed="${1:-}"; [ -n "$feed" ] || usage; shift
  version=""; date=""; notes=""; notes_url=""; min=""; security=false; replace=false; breaking=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --version) version="${2:-}"; shift 2 ;;
      --date) date="${2:-}"; shift 2 ;;
      --notes) notes="${2:-}"; shift 2 ;;
      --notes-url) notes_url="${2:-}"; shift 2 ;;
      --min-upgrade-from) min="${2:-}"; shift 2 ;;
      --breaking) breaking+=("${2:-}"); shift 2 ;;
      --security) security=true; shift ;;
      --replace) replace=true; shift ;;
      *) stop "add: unknown argument $1" ;;
    esac
  done
  printf '%s\n' "$version" | grep -E "$SEMVER" >/dev/null || stop "--version '$version' is not X.Y.Z (no leading v)"
  printf '%s\n' "$date" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' >/dev/null || stop "--date '$date' is not YYYY-MM-DD"
  [ -z "$min" ] || printf '%s\n' "$min" | grep -E "$SEMVER" >/dev/null || stop "--min-upgrade-from '$min' is not X.Y.Z"
  case "$notes_url" in ""|https://*) ;; *) stop "--notes-url must be https://" ;; esac
  # the feed is public text: no internal tracker ids
  for t in "$notes" ${breaking[@]+"${breaking[@]}"}; do
    if printf '%s\n' "$t" | grep -E '(^|[^A-Za-z0-9])(TM|HL|EF|ST)-[0-9]{4}([^0-9]|$)' >/dev/null; then stop "public text carries an internal tracker id: $t"; fi
  done
  python3 -I - "$feed" "$version" "$date" "$notes" "$notes_url" "$min" "$security" "$replace" ${breaking[@]+"${breaking[@]}"} <<'PY'
import json, os, sys
feed, version, date, notes, url, mn, security, replace = sys.argv[1:9]
breaking = sys.argv[9:]
def key(v):
    return tuple(int(x) for x in v.split("."))
doc = {"schema": 1, "releases": []}
if os.path.exists(feed):
    doc = json.load(open(feed))
    if doc.get("schema") != 1 or not isinstance(doc.get("releases"), list):
        sys.exit("STOP: %s is not a schema 1 feed" % feed)
entry = {"version": version, "date": date}
if notes: entry["notes"] = notes
if url: entry["notesUrl"] = url
if mn: entry["minUpgradeFrom"] = mn
entry["breaking"] = breaking
if security == "true": entry["security"] = True
old = [r for r in doc["releases"] if r.get("version") == version]
if old and replace != "true":
    sys.exit("STOP: %s already lists %s; pass --replace to rewrite that entry" % (feed, version))
rel = [r for r in doc["releases"] if r.get("version") != version] + [entry]
rel.sort(key=lambda r: key(r["version"]), reverse=True)
doc["releases"] = rel
doc.pop("signed", None); doc.pop("expires", None)          # an edited feed is unsigned until `sign`
open(feed, "w").write(json.dumps(doc, indent=2) + "\n")
print("added %s to %s (%d releases); unsigned until: release-feed.sh sign %s KEY" % (version, feed, len(rel), feed))
PY
  rm -f "$feed.sig"
}

cmd_sign() {
  feed="${1:-}"; keyf="${2:-}"; [ -n "$feed" ] && [ -n "$keyf" ] || usage; shift 2
  pins=()
  while [ $# -gt 0 ]; do
    case "$1" in --pin) pins+=("${2:-}"); shift 2 ;; *) stop "sign: unknown argument $1" ;; esac
  done
  need_openssl
  [ -s "$feed" ] || stop "no feed $feed (make it with add)"
  [ -r "$keyf" ] || stop "cannot read KEY $keyf"
  pub=$(pub_of "$keyf") || true
  [ ${#pub} = 44 ] || stop "KEY $keyf is not an Ed25519 private key OpenSSL can read"
  if [ ${#pins[@]} -gt 0 ]; then
    hit=0; for p in "${pins[@]}"; do [ "$p" = "$pub" ] && hit=1; done
    [ "$hit" = 1 ] || stop "KEY's public half ($pub) is not one of the pinned keys: a feed signed with it verifies against nothing the console holds"
  fi
  now=$(date +%s)
  python3 -I - "$feed" "$now" "$EXPIRES_DAYS" <<'PY'
import json, sys
feed, now, days = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
doc = json.load(open(feed))
if doc.get("schema") != 1 or not isinstance(doc.get("releases"), list) or not doc["releases"]:
    sys.exit("STOP: %s is not a schema 1 feed with at least one release" % feed)
out = {"schema": 1, "signed": now, "expires": now + days * 86400, "releases": doc["releases"]}
open(feed, "w").write(json.dumps(out, indent=2) + "\n")
PY
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  "$OPENSSL" pkeyutl -sign -inkey "$keyf" -rawin -in "$feed" -out "$tmp/sig" 2>/dev/null || stop "openssl could not sign $feed with $keyf"
  base64 < "$tmp/sig" | tr -d '\n' > "$feed.sig"; printf '\n' >> "$feed.sig"
  cmd_verify "$feed" "$pub" >/dev/null || stop "the signature just written does not verify with KEY's own public half; $feed.sig is not usable"
  say "signed $feed with key $pub; expires in $EXPIRES_DAYS days ($(python3 -I -c 'import json,sys,time; print(time.strftime("%Y-%m-%d", time.gmtime(json.load(open(sys.argv[1]))["expires"])))' "$feed"))"
  say "publish both: $feed and $feed.sig"
}

cmd_verify() {
  feed="${1:-}"; [ -n "$feed" ] && [ $# -ge 2 ] || usage; shift
  need_openssl
  [ -s "$feed" ] && [ -s "$feed.sig" ] || stop "need $feed and $feed.sig"
  tmp=$(mktemp -d)
  base64 -d < "$feed.sig" > "$tmp/sig" 2>/dev/null || { rm -rf "$tmp"; stop "$feed.sig is not base64"; }
  ok=""
  for k in "$@"; do
    if pem_of_raw "$k" "$tmp/pub.pem" \
       && "$OPENSSL" pkeyutl -verify -pubin -inkey "$tmp/pub.pem" -rawin -in "$feed" -sigfile "$tmp/sig" >/dev/null 2>&1; then
      ok="$k"; break
    fi
  done
  rm -rf "$tmp"
  [ -n "$ok" ] || stop "$feed's signature verifies with none of the given keys"
  python3 -I - "$feed" "$(date +%s)" <<'PY'
import json, sys
doc, now = json.load(open(sys.argv[1])), int(sys.argv[2])
if doc.get("schema") != 1 or not isinstance(doc.get("releases"), list):
    sys.exit("STOP: the feed has an unknown format")
exp = doc.get("expires")
if not isinstance(exp, (int, float)):
    sys.exit("STOP: the feed has no expires; the console would accept a replay of it forever")
if exp < now:
    sys.exit("STOP: the feed expired %d day(s) ago" % ((now - exp) // 86400 + 1))
print("verified: %d release(s), newest %s, expires in %d day(s)" % (
    len(doc["releases"]), (doc["releases"][0].get("version") if doc["releases"] else "none"), (exp - now) // 86400))
PY
}

cmd_due() {
  src="${1:-}"; [ -n "$src" ] || usage; shift
  days=30
  while [ $# -gt 0 ]; do
    case "$1" in --days) days="${2:-}"; shift 2 ;; *) stop "due: unknown argument $1" ;; esac
  done
  case "$days" in ''|*[!0-9]*) stop "--days is a whole number" ;; esac
  tmp=$(mktemp)
  case "$src" in
    https://*)
      # the feed itself, to read its dates; its signature is checked by `verify`, not here
      curl -fsS --max-time 30 -o "$tmp" "$src" || { rm -f "$tmp"; echo "cannot fetch $src" >&2; exit 1; } ;;
    *) [ -s "$src" ] || { rm -f "$tmp"; echo "no feed $src" >&2; exit 1; }; cp "$src" "$tmp" ;;
  esac
  rc=0
  python3 -I - "$tmp" "$(date +%s)" "$days" "$EXPIRES_DAYS" <<'PY' || rc=$?
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except ValueError:
    print("the feed is not JSON"); sys.exit(1)
now, days, life = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
signed = doc.get("signed")
if not isinstance(signed, (int, float)):
    exp = doc.get("expires")
    if not isinstance(exp, (int, float)):
        print("the feed carries neither signed nor expires"); sys.exit(1)
    signed = exp - life * 86400
age = (now - signed) // 86400
if age >= days:
    print("RE-SIGN: the release feed was signed %d day(s) ago; it expires %d day(s) after signing. "
          "Run release-feed.sh sign with the feed key." % (age, life))
    sys.exit(3)
print("fresh: signed %d day(s) ago" % age)
PY
  rm -f "$tmp"
  exit "$rc"
}

cmd_pubkey() {
  [ -n "${1:-}" ] || usage
  need_openssl
  pub=$(pub_of "$1") || true
  [ ${#pub} = 44 ] || stop "$1 is not an Ed25519 private key OpenSSL can read"
  say "$pub"
}

# ---------------------------------------------------------------- selftest
selftest_main() {
  need_openssl
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  FAILS=0
  ok()  { echo "  ok  $1"; }
  bad() { echo "  SELFTEST FAIL: $1"; FAILS=1; }
  expect() { # LABEL WANT-RC GREP -- CMD...
    l="$1"; want="$2"; pat="$3"; shift 4
    rc=0; out=$("$@" 2>&1) || rc=$?
    if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -F -- "$pat" >/dev/null; then ok "$l (exit $rc)"
    else bad "$l: wanted exit $want with '$pat', got exit $rc: $(printf '%s' "$out" | tail -3)"; fi
  }
  echo "selftest: release-feed in $T (throwaway keys made here; no network)"
  "$OPENSSL" genpkey -algorithm ed25519 -out "$T/key.pem" 2>/dev/null
  "$OPENSSL" genpkey -algorithm ed25519 -out "$T/next.pem" 2>/dev/null
  "$OPENSSL" genpkey -algorithm ed25519 -out "$T/other.pem" 2>/dev/null
  PUB=$("$SELF" pubkey "$T/key.pem"); NEXT=$("$SELF" pubkey "$T/next.pem"); OTHER=$("$SELF" pubkey "$T/other.pem")
  F="$T/releases.json"

  expect "add refuses a version with a leading v" 1 "is not X.Y.Z" -- "$SELF" add "$F" --version v0.9.0 --date 2026-12-08
  expect "add refuses a bad date" 1 "is not YYYY-MM-DD" -- "$SELF" add "$F" --version 0.9.0 --date 12/08/2026
  expect "add refuses a tracker id in public text" 1 "internal tracker id" -- "$SELF" add "$F" --version 0.9.0 --date 2026-12-08 --notes "fixes $(printf '%s-%s' TM 1234)"   # built here so this file carries no tracker id
  expect "add refuses an http notes URL" 1 "must be https://" -- "$SELF" add "$F" --version 0.9.0 --date 2026-12-08 --notes-url http://x
  expect "add writes the first release" 0 "added 0.8.6" -- "$SELF" add "$F" --version 0.8.6 --date 2026-11-17 --notes "Patch release."
  expect "add writes a second release" 0 "added 0.9.0" -- "$SELF" add "$F" --version 0.9.0 --date 2026-12-08 --notes "Hardening." --breaking "Open WebUI 0.13 migrates its database" --min-upgrade-from 0.8.6
  expect "add refuses a version already listed" 1 "already lists 0.9.0" -- "$SELF" add "$F" --version 0.9.0 --date 2026-12-08
  if python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1]))["releases"]; sys.exit(0 if [x["version"] for x in r]==["0.9.0","0.8.6"] else 1)' "$F"; then ok "releases are newest first"; else bad "releases are not newest first"; fi
  expect "an unsigned feed does not verify" 1 "need" -- "$SELF" verify "$F" "$PUB"
  expect "sign refuses a key that is not pinned" 1 "not one of the pinned keys" -- "$SELF" sign "$F" "$T/other.pem" --pin "$PUB" --pin "$NEXT"
  if [ ! -e "$F.sig" ]; then ok "a refused sign writes no .sig"; else bad "a refused sign left $F.sig"; fi
  expect "sign with a pinned key" 0 "signed $F with key $PUB" -- "$SELF" sign "$F" "$T/key.pem" --pin "$PUB" --pin "$NEXT"
  if python3 -I -c 'import json,sys,time; d=json.load(open(sys.argv[1])); n=time.time(); sys.exit(0 if d["schema"]==1 and abs(d["expires"]-d["signed"]-45*86400)<2 and abs(d["signed"]-n)<120 else 1)' "$F"; then ok "expires is 45 days after signed"; else bad "expires is not 45 days after signed"; fi
  expect "verify with the signing key" 0 "verified: 2 release(s), newest 0.9.0" -- "$SELF" verify "$F" "$PUB"
  expect "verify with the pinned pair, the current key second" 0 "verified" -- "$SELF" verify "$F" "$NEXT" "$PUB"
  expect "verify refuses another key" 1 "verifies with none of the given keys" -- "$SELF" verify "$F" "$OTHER"
  cp "$F" "$T/good.json"; cp "$F.sig" "$T/good.json.sig"
  sed 's/Hardening\./Hardening!/' "$T/good.json" > "$T/tampered.json"; cp "$F.sig" "$T/tampered.json.sig"
  expect "verify refuses a feed changed after signing" 1 "verifies with none of the given keys" -- "$SELF" verify "$T/tampered.json" "$PUB"
  # an expired feed, signed for real with expires in the past
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["signed"]-=50*86400; d["expires"]-=50*86400; open(sys.argv[2],"w").write(json.dumps(d,indent=2)+"\n")' "$F" "$T/old.json"
  "$OPENSSL" pkeyutl -sign -inkey "$T/key.pem" -rawin -in "$T/old.json" -out "$T/old.raw" 2>/dev/null
  base64 < "$T/old.raw" | tr -d '\n' > "$T/old.json.sig"
  expect "verify refuses an expired feed" 1 "expired" -- "$SELF" verify "$T/old.json" "$PUB"
  expect "due says RE-SIGN on a feed signed 50 days ago" 3 "RE-SIGN" -- "$SELF" due "$T/old.json"
  expect "due is quiet on a feed signed today" 0 "fresh: signed 0 day(s) ago" -- "$SELF" due "$F"
  expect "due with --days 0 says RE-SIGN on a feed signed today" 3 "RE-SIGN" -- "$SELF" due "$F" --days 0
  expect "add after signing leaves the feed unsigned" 0 "unsigned until" -- "$SELF" add "$F" --version 0.9.1 --date 2026-12-20
  if [ ! -e "$F.sig" ]; then ok "add removed the stale .sig"; else bad "add left a .sig that no longer matches"; fi
  # the console's own verifier, when its libraries are here
  if python3 -c 'import cryptography' 2>/dev/null; then
    "$SELF" sign "$F" "$T/key.pem" >/dev/null
    if python3 -I - "$F" "$PUB" <<'PY'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
body = open(sys.argv[1], "rb").read(); sig = base64.b64decode(open(sys.argv[1] + ".sig", "rb").read().strip(), validate=True)
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[2], validate=True)).verify(sig, body)
d = json.loads(body); assert d["schema"] == 1 and isinstance(d["releases"], list) and isinstance(d["expires"], int)
PY
    then ok "the console's verifier (cryptography Ed25519) accepts the signed feed"
    else bad "the console's verifier refuses the signed feed"; fi
  else
    echo "  note: python cryptography is not here, so the console's own verifier was not run (openssl verified above)"
  fi
  if [ "$FAILS" = 0 ]; then echo "release-feed --selftest: PASSED"; exit 0; fi
  echo "release-feed --selftest: FAILED"; exit 1
}

case "${1:-}" in
  add) shift; cmd_add "$@" ;;
  sign) shift; cmd_sign "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  due) shift; cmd_due "$@" ;;
  pubkey) shift; cmd_pubkey "$@" ;;
  --selftest) selftest_main ;;
  *) usage ;;
esac

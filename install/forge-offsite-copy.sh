#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# forge-offsite-copy.sh - keep an off-site copy of one repository's main
# branch held by the in-cluster forge, and succeed only when that copy
# holds the forge's current main.
#
# Run every minute by the CronJob tockmox-forge-offsite, which is created by
# install/bootstrap-forge.sh. The exit code is the health signal.
#
# Exit codes:
#   0  in step: the off-site copy holds the forge's current main
#   1  behind, or anything failed or was doubtful
#   2  misconfigured (bad MODE, missing input, unreadable/empty secret)
#
# MODE=bucket: objects live under S3_PREFIX (if any):
#   latest                    small text object, replaced on each new copy
#   bundles/<STAMP>-<sha12>.bundle        git bundle, written once
#   bundles/<STAMP>-<sha12>.bundle.sha256 "<sum>  site.bundle"
# Format of "latest" (one field per line):
#   format tockmox-site-copy v1
#   commit <40-hex sha>
#   bundle <key of the bundle object>
#   sha256 <sha256 of the bundle>
#   created <UTC stamp, YYYYmmddTHHMMSSZ>
#   repository <REPO>
#
# MODE=git: verify only. The forge's own push mirror does the pushing; this
# script just compares the remote's main with the forge's main.

set -eu

WORK=""
HOME_DIR=""
S3_STATUS=""
S3_OUT=""

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
	[ -z "$WORK" ] || rm -rf "$WORK"
	[ -z "$HOME_DIR" ] || rm -rf "$HOME_DIR"
}

die_cfg() {
	echo "forge-offsite-copy: $*" >&2
	exit 2
}

die() {
	echo "forge-offsite-copy: $*" >&2
	exit 1
}

need() {
	eval "need_v=\${$1:-}"
	[ -n "$need_v" ] || die_cfg "missing required input $1"
}

short() {
	printf '%.12s' "$1"
}

is_sha() {
	printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# Print a secret file's content; never echo it elsewhere.
read_secret() {
	[ -r "$1" ] || die_cfg "cannot read secret file $1"
	rs_v=$(cat "$1")
	[ -n "$rs_v" ] || die_cfg "secret file $1 is empty"
	printf '%s' "$rs_v"
}

# githdr USERFILE PASSFILE -> header value for http.extraHeader.
# base64 wraps lines, so strip newlines to keep a single header line.
githdr() {
	gh_u=$(read_secret "$1") || exit 2
	gh_p=$(read_secret "$2") || exit 2
	gh_b=$(printf '%s:%s' "$gh_u" "$gh_p" | base64 | tr -d '\n')
	printf 'Authorization: Basic %s' "$gh_b"
}

# Credentials go through the environment of this one command only.
forge_git() {
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
		GIT_CONFIG_VALUE_0="$FORGE_HDR" GIT_TERMINAL_PROMPT=0 git "$@"
}

remote_git() {
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
		GIT_CONFIG_VALUE_0="$REMOTE_HDR" GIT_TERMINAL_PROMPT=0 git "$@"
}

# First field of the first ls-remote line (empty if none).
first_sha() {
	awk 'NR==1{print $1}'
}

key_of() {
	if [ -n "$S3_PREFIX" ]; then
		printf '%s/%s' "$S3_PREFIX" "$1"
	else
		printf '%s' "$1"
	fi
}

# s3 METHOD KEY [BODYFILE] [OUTFILE]
# Sets S3_STATUS and S3_OUT, and echoes the status. The key pair is fed to
# curl as a config on stdin so it never reaches argv; hence uploads must
# come from a file.
s3() {
	s3_method=$1
	s3_key=$2
	s3_body=${3:-}
	S3_OUT=${4:-$WORK/s3.out}
	set -- -sS -K - --aws-sigv4 "aws:amz:${S3_REGION}:s3" \
		--connect-timeout 15 --max-time 600 \
		-o "$S3_OUT" -w '%{http_code}'
	if [ -n "$S3_CA_FILE" ]; then
		set -- "$@" --cacert "$S3_CA_FILE"
	fi
	case $s3_method in
	HEAD) set -- "$@" --head ;;
	PUT) set -- "$@" --upload-file "$s3_body" ;;
	GET) ;;
	*) die "internal: bad s3 method $s3_method" ;;
	esac
	set -- "$@" "$S3_ENDPOINT/$S3_BUCKET/$s3_key"
	S3_STATUS=$(printf 'user = "%s:%s"\n' "$AK" "$SK" | curl "$@") || S3_STATUS=000
	echo "$S3_STATUS"
}

# Fail unless the last s3 call returned 2xx.
need_2xx() {
	case $S3_STATUS in
	2??) ;;
	*)
		echo "forge-offsite-copy: $1 failed: HTTP $S3_STATUS" >&2
		[ ! -s "$S3_OUT" ] || head -c 300 "$S3_OUT" >&2
		echo >&2
		exit 1
		;;
	esac
}

sha_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# ---- configuration ----------------------------------------------------

MODE=${MODE:-}
case $MODE in
bucket | git) ;;
*) die_cfg "MODE must be bucket or git" ;;
esac

need FORGE_URL
need REPO
BRANCH=${BRANCH:-main}
SECRETS_DIR=${SECRETS_DIR:-/run/offsite}
FORGE_URL=${FORGE_URL%/}

S3_REGION=${S3_REGION:-us-east-1}
S3_PREFIX=${S3_PREFIX:-}
S3_CA_FILE=${S3_CA_FILE:-}
S3_ENDPOINT=${S3_ENDPOINT:-}
S3_BUCKET=${S3_BUCKET:-}
GIT_REMOTE_URL=${GIT_REMOTE_URL:-}

FORGE_HDR=$(githdr "$SECRETS_DIR/forge-username" "$SECRETS_DIR/forge-token") || exit 2

REMOTE_HDR=""
AK=""
SK=""
if [ "$MODE" = git ]; then
	need GIT_REMOTE_URL
	REMOTE_HDR=$(githdr "$SECRETS_DIR/git-username" "$SECRETS_DIR/git-password") || exit 2
else
	need S3_ENDPOINT
	need S3_BUCKET
	S3_ENDPOINT=${S3_ENDPOINT%/}
	AK=$(read_secret "$SECRETS_DIR/s3-access-key-id") || exit 2
	SK=$(read_secret "$SECRETS_DIR/s3-secret-access-key") || exit 2
	# The pair travels inside a quoted curl config line; a quote or backslash would end it early.
	case "$AK$SK" in *\"* | *\\*) die_cfg "the S3 key pair contains a quote or a backslash, which this script cannot pass safely" ;; esac
fi

# ---- scratch space ----------------------------------------------------

trap cleanup EXIT
# The image sets TMPDIR=/tmp/gitea, which only the forge itself creates; the CronJob mounts an
# emptyDir at /tmp.
TMPDIR=/tmp
export TMPDIR
trap 'exit 143' INT TERM HUP
HOME_DIR=$(mktemp -d) || die "cannot create temp dir"
WORK=$(mktemp -d) || die "cannot create work dir"
HOME=$HOME_DIR
export HOME

# ---- step 1: the forge's main -----------------------------------------

# Retried: a NetworkPolicy controller (kube-router, measured on k3s) can take ~10 s
# to admit a pod that has just started, and this pod connects at once.
tries=0
until out=$(forge_git ls-remote "$FORGE_URL/$REPO.git" "refs/heads/$BRANCH" 2>"$WORK/ls-remote.err"); do
	tries=$((tries + 1))
	[ "$tries" -lt 6 ] || die "cannot read the forge's main after $tries tries: $(tail -1 "$WORK/ls-remote.err")"
	sleep 5
done
HEAD=$(printf '%s\n' "$out" | first_sha)
is_sha "$HEAD" || die "cannot read the forge's main"

# ---- step 2: git mode (verify only) -----------------------------------

if [ "$MODE" = git ]; then
	rsha=""
	if out=$(remote_git ls-remote "$GIT_REMOTE_URL" "refs/heads/$BRANCH" 2>/dev/null); then
		rsha=$(printf '%s\n' "$out" | first_sha)
	fi
	if is_sha "$rsha" && [ "$rsha" = "$HEAD" ]; then
		echo "in step: $GIT_REMOTE_URL main is $(short "$HEAD")"
		exit 0
	fi
	if is_sha "$rsha"; then
		rshow=$(short "$rsha")
	else
		rshow=unreadable
	fi
	echo "behind: forge main $(short "$HEAD"), $GIT_REMOTE_URL main $rshow"
	exit 1
fi

# ---- step 3: bucket mode ----------------------------------------------

LATEST=$(key_of latest)

# a. Is the existing copy already current?
s3 GET "$LATEST" "" "$WORK/latest.txt" >/dev/null
case $S3_STATUS in
200)
	cur=$(awk '$1=="commit"{print $2; exit}' "$WORK/latest.txt")
	bkey=$(awk '$1=="bundle"{print $2; exit}' "$WORK/latest.txt")
	if [ "$cur" = "$HEAD" ] && [ -n "$bkey" ] &&
		printf '%s\n' "$bkey" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
		s3 HEAD "$bkey" >/dev/null
		if [ "$S3_STATUS" = 200 ]; then
			echo "in step: bucket $S3_BUCKET main is $(short "$HEAD")"
			exit 0
		fi
	fi
	;;
404) ;; # no copy yet
*) need_2xx "read of latest" ;;
esac

# b. Clone. main may have moved since step 1, so the copy's SHA is what
# was actually cloned.
forge_git clone --quiet --bare --single-branch --branch "$BRANCH" \
	"$FORGE_URL/$REPO.git" "$WORK/repo.git" || die "clone from forge failed"
SHA=$(git -C "$WORK/repo.git" rev-parse "refs/heads/$BRANCH") ||
	die "cannot read cloned head"
is_sha "$SHA" || die "cloned head is not a sha"

# c. Bundle, then verify it from an empty repo: a bare repo cannot verify
# against itself, and a full-history bundle needs no prerequisites.
# HEAD too, so a plain `git clone site.bundle` checks out main.
git -C "$WORK/repo.git" bundle create "$WORK/site.bundle" HEAD "refs/heads/$BRANCH" >/dev/null 2>&1 ||
	die "bundle create failed"
git init --bare --quiet "$WORK/empty.git" || die "cannot init verify repo"
git -C "$WORK/empty.git" bundle verify "$WORK/site.bundle" >/dev/null 2>&1 ||
	die "bundle verify failed"

# d. Upload bundle and checksum. Bundle keys are unique (stamp + sha) and
# are never overwritten or deleted; only "latest" is replaced. With bucket
# versioning or object lock, every earlier history is therefore kept.
SUM=$(sha_of "$WORK/site.bundle")
BYTES=$(wc -c <"$WORK/site.bundle" | tr -d ' ')
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
KEY=$(key_of "bundles/$STAMP-$(short "$SHA").bundle")

s3 PUT "$KEY" "$WORK/site.bundle" >/dev/null
need_2xx "upload of bundle"

printf '%s  site.bundle\n' "$SUM" >"$WORK/site.sha256"
s3 PUT "$KEY.sha256" "$WORK/site.sha256" >/dev/null
need_2xx "upload of checksum"

s3 GET "$KEY" "" "$WORK/back.bundle" >/dev/null
need_2xx "read-back of bundle"
BACK=$(sha_of "$WORK/back.bundle")
[ "$BACK" = "$SUM" ] || die "bundle read-back checksum mismatch"

# e. Publish the pointer last, so latest never names a missing bundle.
{
	echo "format tockmox-site-copy v1"
	echo "commit $SHA"
	echo "bundle $KEY"
	echo "sha256 $SUM"
	echo "created $STAMP"
	echo "repository $REPO"
} >"$WORK/latest.new"
s3 PUT "$LATEST" "$WORK/latest.new" >/dev/null
need_2xx "upload of latest"

s3 GET "$LATEST" "" "$WORK/latest.back" >/dev/null
need_2xx "read-back of latest"
got=$(awk '$1=="commit"{print $2; exit}' "$WORK/latest.back")
[ "$got" = "$SHA" ] || die "latest read-back does not name $(short "$SHA")"

# g. Done.
echo "copied: $(short "$SHA") to $KEY ($BYTES bytes, sha256 $(short "$SUM"))"
exit 0
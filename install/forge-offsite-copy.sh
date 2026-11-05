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
# TASK=dump (default copy) is the same script run once a night by the CronJob
# tockmox-forge-dump: it writes the forge dump (pull requests, reviews and comments,
# which git does not carry) to the same destination instead. See "the nightly forge
# dump" below; a failed dump leaves a failed Job, which KubeJobFailed reports.
#
# TASK=drill-check is run once a day by the CronJob tockmox-forge-drill-check. It
# reads the record the last rebuild drill left at the destination (written by
# `tockmox-install.sh --restore-from offsite --drill`) and succeeds only when that
# drill passed and is younger than DRILL_MAX_DAYS (default 92, a quarter). Its
# success is the health signal: TockmoxSiteRebuildDrillOverdue fires when it has
# not succeeded for a day. A site with no drill on record yet is given one quarter
# from its install (DRILL_SINCE). It reads the destination only, never the forge.
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
#
# The rebuild drill's record (TASK=drill-check reads it): the object drill/latest
# in a bucket (beside drill/<STAMP>, written once), or the file drill/latest on the
# git remote's branch forge-drill. One field per line:
#   format tockmox-rebuild-drill v1
#   result pass|fail
#   created <UTC stamp, YYYYmmddTHHMMSSZ>
#   copy-commit <40-hex sha the drill rebuilt from>
#   seconds <wall time of the rebuild>
#   refusals <the refusals the drill proved, comma-separated>
#   reason <one line, on a fail>

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

TASK=${TASK:-copy}
case $TASK in
copy | dump | drill-check) ;;
*) die_cfg "TASK must be copy, dump or drill-check" ;;
esac
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

DRILL_MAX_DAYS=${DRILL_MAX_DAYS:-92}
printf '%s\n' "$DRILL_MAX_DAYS" | grep -Eq '^[1-9][0-9]{0,3}$' || die_cfg "DRILL_MAX_DAYS must be a whole number of days, 1 to 9999"

FORGE_HDR=""
if [ "$TASK" != drill-check ]; then
	FORGE_HDR=$(githdr "$SECRETS_DIR/forge-username" "$SECRETS_DIR/forge-token") || exit 2
fi

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

# ---- the rebuild drill's record (TASK=drill-check) -------------------------
#
# A stamp is YYYYmmddTHHMMSSZ. Its age is worked out in awk, not with date -d,
# which busybox date (the forge image's) reads differently from GNU date.
stamp_secs() {
	printf '%s\n' "$1" | awk '
	/^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z$/ {
		y = substr($0, 1, 4) + 0; m = substr($0, 5, 2) + 0; d = substr($0, 7, 2) + 0
		H = substr($0, 10, 2) + 0; M = substr($0, 12, 2) + 0; S = substr($0, 14, 2) + 0
		if (m < 1 || m > 12 || d < 1 || d > 31 || H > 23 || M > 59 || S > 59) exit 1
		if (m <= 2) { y -= 1; m += 12 }
		days = 365 * y + int(y / 4) - int(y / 100) + int(y / 400) + int((153 * (m - 3) + 2) / 5) + d - 719469
		print days * 86400 + H * 3600 + M * 60 + S; ok = 1
	}
	END { if (!ok) exit 1 }'
}

# field KEY FILE: the rest of the first line whose first word is KEY.
field() {
	awk -v k="$1" '$1 == k { sub(/^[^ ]+ /, ""); print; exit }' "$2"
}

# no_record WHAT: a site younger than a quarter (DRILL_SINCE, the install's stamp, set by
# bootstrap-forge) is not overdue yet: it says when the first drill is due and succeeds.
no_record() {
	if [ -n "${DRILL_SINCE:-}" ] && ss=$(stamp_secs "$DRILL_SINCE"); then
		left=$(((ss + DRILL_MAX_DAYS * 86400 - $(date -u +%s)) / 86400))
		if [ "$left" -ge 0 ]; then
			echo "rebuild drill: none on record yet ($1); the first is due within $left days (installed $DRILL_SINCE)"
			exit 0
		fi
	fi
	die "no rebuild drill on record: $1. Run the drill (docs/administration/site-forge-recovery.md, The rebuild drill)."
}

if [ "$TASK" = drill-check ]; then
	REC=$WORK/drill-latest
	if [ "$MODE" = git ]; then
		DR=$WORK/drillrepo
		git init -q "$DR" || die "cannot init a scratch repository"
		out=$(remote_git ls-remote "$GIT_REMOTE_URL" refs/heads/forge-drill 2>"$WORK/ls.err") ||
			die "cannot read $GIT_REMOTE_URL: $(tail -1 "$WORK/ls.err")"
		rsha=$(printf '%s\n' "$out" | first_sha)
		is_sha "$rsha" || no_record "$GIT_REMOTE_URL has no forge-drill branch"
		remote_git -C "$DR" fetch -q --depth 1 "$GIT_REMOTE_URL" forge-drill || die "cannot fetch forge-drill from $GIT_REMOTE_URL"
		git -C "$DR" show FETCH_HEAD:drill/latest >"$REC" 2>/dev/null || die "forge-drill on $GIT_REMOTE_URL holds no drill/latest"
		WHERE="$GIT_REMOTE_URL forge-drill"
	else
		s3 GET "$(key_of drill/latest)" "" "$REC" >/dev/null
		[ "$S3_STATUS" != 404 ] || no_record "$(key_of drill/latest) is not in $S3_BUCKET"
		need_2xx "reading $(key_of drill/latest)"
		WHERE="$S3_BUCKET/$(key_of drill/latest)"
	fi
	[ "$(sed -n 1p "$REC")" = "format tockmox-rebuild-drill v1" ] || die "$WHERE is not a rebuild-drill record (format tockmox-rebuild-drill v1)"
	result=$(field result "$REC")
	created=$(field created "$REC")
	csecs=$(stamp_secs "$created") || die "$WHERE: created '$created' is not a YYYYmmddTHHMMSSZ stamp"
	now=$(date -u +%s)
	[ "$csecs" -le "$((now + 300))" ] || die "$WHERE: the drill's date $created is in the future; this clock or the record is wrong"
	age_days=$(((now - csecs) / 86400))
	case $result in
	pass) ;;
	fail) die "the last rebuild drill ($created) FAILED: $(field reason "$REC"). Fix it and run the drill again." ;;
	*) die "$WHERE: result '$result' is neither pass nor fail" ;;
	esac
	[ "$age_days" -lt "$DRILL_MAX_DAYS" ] || die "the last rebuild drill passed on $created, $age_days days ago: overdue (one is due every $DRILL_MAX_DAYS days). Run it again."
	echo "rebuild drill: passed $created ($age_days days ago) in $(field seconds "$REC") s, from $(short "$(field copy-commit "$REC")"); refusals proven: $(field refusals "$REC")"
	exit 0
fi

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

# ---- the nightly forge dump (TASK=dump) -----------------------------------
#
# What git does not carry: the pull requests, the reviews and the comments on them,
# and the repository's settings as the forge reports them. The forge has no
# `forgejo restore`, and `forgejo dump` needs the forge's volume, which this job
# does not mount; the API is what a read-only machine user can reach, so the dump is
# the API's own JSON, stored as received (one file per page) beside a MANIFEST that
# counts what it holds. It goes to the same place as the copy: a bucket (a new
# object under dumps/, never overwritten or deleted, and a small `latest-dump`
# pointer replaced last) or the git remote (a new commit on the branch forge-dump,
# pushed without force). The job exits 0 only when the dump was written and read back.

FORGE_API_ERR=""

# forge_api PATH OUTFILE: GET <forge>/api/v1PATH into OUTFILE; 0 on 2xx. The credential
# reaches curl as a config on stdin, never in argv.
forge_api() {
	fa_code=$(printf 'header = "%s"\n' "$FORGE_HDR" |
		curl -sS -K - --connect-timeout 15 --max-time 120 -o "$2" -w '%{http_code}' \
			"$FORGE_URL/api/v1$1" 2>"$WORK/api.err") || fa_code=000
	case $fa_code in
	2??) return 0 ;;
	esac
	FORGE_API_ERR="forge API $1 failed: HTTP $fa_code $(head -c 200 "$WORK/api.err" | tr '\n' ' ')"
	return 1
}

# fetch_pages PATHPREFIX NAME: PATHPREFIX ends in ? or &; pages of 50 go to
# $DUMP/NAME-<page>.json until the forge answers an empty list.
fetch_pages() {
	fp_n=1
	while :; do
		forge_api "${1}limit=50&page=$fp_n" "$DUMP/$2-$fp_n.json" || die "$FORGE_API_ERR"
		if [ "$(tr -d ' \r\n\t' <"$DUMP/$2-$fp_n.json")" = "[]" ]; then
			rm -f "$DUMP/$2-$fp_n.json"
			break
		fi
		fp_n=$((fp_n + 1))
		[ "$fp_n" -le 400 ] || die "more than 400 pages of $2; refusing to go on"
	done
}

# count_in PATTERN FILE...: how many times PATTERN occurs (JSON is one line, so grep -c is no count).
count_in() {
	ci_p=$1
	shift
	cat "$@" 2>/dev/null | grep -o "$ci_p" | wc -l | tr -d ' '
}

if [ "$TASK" = dump ]; then
	STAMP=$(date -u +%Y%m%dT%H%M%SZ)
	DUMP=$WORK/dump
	mkdir "$DUMP" || die "cannot create dump dir"

	forge_api "/version" "$DUMP/version.json" || die "$FORGE_API_ERR"
	forge_api "/repos/$REPO" "$DUMP/repository.json" || die "$FORGE_API_ERR"
	fetch_pages "/repos/$REPO/pulls?state=all&" pulls
	fetch_pages "/repos/$REPO/issues/comments?" issue-comments

	NPRS=0
	NREV=0
	if ls "$DUMP"/pulls-*.json >/dev/null 2>&1; then
		prs=$(cat "$DUMP"/pulls-*.json | grep -o '"html_url": *"[^"]*/pulls/[0-9]*"' |
			sed 's/.*\/pulls\/\([0-9]*\)"$/\1/' | sort -un)
		for n in $prs; do
			NPRS=$((NPRS + 1))
			fetch_pages "/repos/$REPO/pulls/$n/reviews?" "reviews-$n"
			ls "$DUMP/reviews-$n"-*.json >/dev/null 2>&1 || continue
			# A review is the only object that opens {"id":N,"user":; its pull_request_url
			# appears once per review, so the two counts must agree or the ids were misread.
			ids=$(cat "$DUMP/reviews-$n"-*.json | grep -o '{"id": *[0-9]*, *"user":' | sed 's/[^0-9]//g')
			have=$(printf '%s\n' "$ids" | grep -c . || true)
			want=$(count_in '"pull_request_url"' "$DUMP/reviews-$n"-*.json)
			[ "$have" = "$want" ] || die "pull request $n: read $have review ids but $want reviews; the forge's review format changed"
			for rid in $ids; do
				NREV=$((NREV + 1))
				forge_api "/repos/$REPO/pulls/$n/reviews/$rid/comments" "$DUMP/review-comments-$n-$rid.json" || die "$FORGE_API_ERR"
			done
		done
	fi
	NRC=$(count_in '"diff_hunk"' "$DUMP"/review-comments-*.json)
	NIC=$(count_in '"issue_url"' "$DUMP"/issue-comments-*.json)

	{
		echo "format tockmox-forge-dump v1"
		echo "repository $REPO"
		echo "created $STAMP"
		echo "forge-main $HEAD"
		echo "pull-requests $NPRS"
		echo "reviews $NREV"
		echo "review-comments $NRC"
		echo "issue-comments $NIC"
		echo "settings repository.json (the repository as the forge reports it); branch rules, teams and sign-in are recreated by bootstrap-forge, not dumped"
	} >"$DUMP/MANIFEST"

	tar -C "$DUMP" -czf "$WORK/dump.tar.gz" . || die "cannot pack the dump"
	tar -tzf "$WORK/dump.tar.gz" >/dev/null || die "the packed dump does not read back"
	DSUM=$(sha_of "$WORK/dump.tar.gz")
	DBYTES=$(wc -c <"$WORK/dump.tar.gz" | tr -d ' ')
	SUMMARY="$NPRS pull requests, $NREV reviews, $NRC review comments, $NIC issue comments"

	if [ "$MODE" = git ]; then
		GD=$WORK/dumprepo
		git init -q "$GD" || die "cannot init dump repo"
		rsha=""
		if out=$(remote_git ls-remote "$GIT_REMOTE_URL" refs/heads/forge-dump 2>/dev/null); then
			rsha=$(printf '%s\n' "$out" | first_sha)
		fi
		if is_sha "$rsha"; then
			remote_git -C "$GD" fetch -q "$GIT_REMOTE_URL" forge-dump || die "cannot fetch the remote's forge-dump branch"
			git -C "$GD" checkout -q -B forge-dump FETCH_HEAD || die "cannot check out forge-dump"
		else
			git -C "$GD" checkout -q --orphan forge-dump || die "cannot start forge-dump"
		fi
		rm -rf "$GD/dump"
		mkdir "$GD/dump"
		tar -C "$GD/dump" -xzf "$WORK/dump.tar.gz" || die "cannot unpack the dump for the remote"
		git -C "$GD" add -A dump
		git -C "$GD" -c user.name=tockmox-forge-dump -c user.email=tockmox-forge-dump@localhost.invalid \
			commit -q --allow-empty -m "Forge dump $STAMP" || die "cannot commit the dump"
		# No --force: a remote that refuses rewrites keeps every earlier dump.
		remote_git -C "$GD" push -q "$GIT_REMOTE_URL" forge-dump || die "push of forge-dump to $GIT_REMOTE_URL failed"
		want=$(git -C "$GD" rev-parse HEAD)
		out=$(remote_git ls-remote "$GIT_REMOTE_URL" refs/heads/forge-dump) || die "cannot read back forge-dump"
		got=$(printf '%s\n' "$out" | first_sha)
		[ "$got" = "$want" ] || die "forge-dump on the remote is $(short "$got"), not the $(short "$want") just pushed"
		echo "dumped: $SUMMARY, to $GIT_REMOTE_URL forge-dump ($(short "$want"))"
		exit 0
	fi

	DKEY=$(key_of "dumps/$STAMP.tar.gz")
	s3 PUT "$DKEY" "$WORK/dump.tar.gz" >/dev/null
	need_2xx "upload of dump"
	printf '%s  dump.tar.gz\n' "$DSUM" >"$WORK/dump.sha256"
	s3 PUT "$DKEY.sha256" "$WORK/dump.sha256" >/dev/null
	need_2xx "upload of dump checksum"
	s3 GET "$DKEY" "" "$WORK/back.tar.gz" >/dev/null
	need_2xx "read-back of dump"
	[ "$(sha_of "$WORK/back.tar.gz")" = "$DSUM" ] || die "dump read-back checksum mismatch"
	{
		echo "format tockmox-forge-dump v1"
		echo "dump $DKEY"
		echo "sha256 $DSUM"
		echo "created $STAMP"
		echo "repository $REPO"
		echo "forge-main $HEAD"
	} >"$WORK/latest-dump.new"
	LDUMP=$(key_of latest-dump)
	s3 PUT "$LDUMP" "$WORK/latest-dump.new" >/dev/null
	need_2xx "upload of latest-dump"
	s3 GET "$LDUMP" "" "$WORK/latest-dump.back" >/dev/null
	need_2xx "read-back of latest-dump"
	got=$(awk '$1=="dump"{print $2; exit}' "$WORK/latest-dump.back")
	[ "$got" = "$DKEY" ] || die "latest-dump read-back does not name $DKEY"
	echo "dumped: $SUMMARY, to $DKEY ($DBYTES bytes, sha256 $(short "$DSUM"))"
	exit 0
fi

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
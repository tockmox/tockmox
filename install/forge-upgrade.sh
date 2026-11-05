#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# forge-upgrade.sh ... move the built-in forge to the Forgejo this Tockmox
# release pins, and only after a fresh off-site copy that a failed upgrade can be
# repaired from.
#
#   ./install/tockmox-install.sh upgrade-forge --context NAME [options]
#
# THE ORDER IS THE PROMISE (specs/site-forge, "Upgrading the forge"). Upgrading
# Tockmox takes a fresh off-site copy, upgrades the forge with the installer,
# checks it answers at the pinned version, and only then moves the site's
# Tockmox pin. This script is the first three; docs/deployment/upgrade.md is the
# fourth. The installer upgrades the forge, never Argo CD: the forge is a
# prerequisite, not a layer, so a broken sync can never take it down.
#
# WHAT IT CHANGES: the forge's Helm release, to the chart and image pinned in
# bootstrap-forge.sh (CHART_VERSION_DEFAULT, FORGE_IMAGE_TAG_DEFAULT), with every
# other value it already has (--reuse-values: they are the ones bootstrap-forge
# wrote). Nothing else: not the branch rule, the teams, the sign-in or the off-site
# jobs, which bootstrap-forge owns.
#
# A FAILED UPGRADE is a forge repair from the copy taken here:
# `tockmox-install.sh repair-forge` (docs/administration/site-forge-recovery.md),
# and the script prints that command. A forge whose data the new version cannot
# read answers nothing, so the repair is the way back, not a helm rollback: a
# Forgejo upgrade migrates its database forward on first start.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE="tockmox-forge"

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
tockmox-install.sh upgrade-forge --context NAME [options]

Move the built-in forge to the Forgejo this release pins, after a fresh off-site
copy. Then move the site's Tockmox pin (docs/deployment/upgrade.md).

  --context NAME           the site's cluster (required; never the current context by default)
  --yes-context NAME       confirm it without a prompt (must equal --context)
  --no-prompt              never ask; refuse unless --yes-context confirms the context
  --namespace NS           the forge's namespace (default tockmox-forge)
  --chart REF              a mirror of the forge's chart (default: the one bootstrap-forge pins)
  --wait-seconds N         how long to wait for the forge (default 300)
  --without-copy           upgrade a forge that has no off-site copy. A failed upgrade then
                           has nothing newer than your last copy to be repaired from
  --dry-run                say what would change; change nothing
  -h, --help               this
USAGE
}

CONTEXT=""; YES_CONTEXT=""; FORGE_NS="tockmox-forge"; CHART_REF=""; WAIT_SECONDS=300
WITHOUT_COPY=false; DRY_RUN=false; NO_PROMPT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CONTEXT="${2:?--context needs a name}"; shift 2 ;;
    --yes-context) YES_CONTEXT="${2:?--yes-context needs the context name}"; shift 2 ;;
    --namespace) FORGE_NS="${2:?--namespace needs a name}"; shift 2 ;;
    --chart) CHART_REF="${2:?--chart needs a reference}"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="${2:?--wait-seconds needs a number}"; shift 2 ;;
    --without-copy) WITHOUT_COPY=true; shift ;;
    --no-prompt) NO_PROMPT=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done

# The pin is bootstrap-forge's, read from its file so there is one place it lives.
pin_of() { sed -n "s/^$1=\"\\([^\"]*\\)\"$/\\1/p" "$HERE/bootstrap-forge.sh" | head -1; }
PIN_CHART="$(pin_of CHART_VERSION_DEFAULT)"; PIN_IMAGE="$(pin_of FORGE_IMAGE_TAG_DEFAULT)"
PIN_REF="$(pin_of CHART_REF_DEFAULT)"; CHART_REF="${CHART_REF:-$PIN_REF}"
[[ -n "$PIN_CHART" && -n "$PIN_IMAGE" && -n "$PIN_REF" ]] || die "cannot read the forge's pin from $HERE/bootstrap-forge.sh"

say "Checking the request"
[[ -n "$CONTEXT" ]] || die "--context is required: name the site's cluster. This never falls back to the current context."
[[ -z "$YES_CONTEXT" || "$YES_CONTEXT" == "$CONTEXT" ]] || die "--yes-context '$YES_CONTEXT' does not match --context '$CONTEXT'. Nothing was touched."
[[ "$FORGE_NS" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--namespace is not a namespace name: '$FORGE_NS'"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ ]] || die "--wait-seconds must be a whole number: '$WAIT_SECONDS'"
for t in kubectl helm; do command -v "$t" >/dev/null 2>&1 || die "missing: $t"; done
K=(--context "$CONTEXT")
SERVER="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CONTEXT\")].context.cluster}")\")].cluster.server}" 2>/dev/null || true)"
info "context $CONTEXT, API server ${SERVER:-unknown}"
if [[ -z "$YES_CONTEXT" ]] && ! $DRY_RUN; then
  if ! $NO_PROMPT && (: < /dev/tty) 2>/dev/null; then
    printf '    Upgrade the forge on %s? Type the context name to go on: ' "$CONTEXT" > /dev/tty
    read -r answer < /dev/tty || answer=""
    [[ "$answer" == "$CONTEXT" ]] || die "not confirmed. Nothing was touched."
  else
    die "nothing to confirm the context with: pass --yes-context $CONTEXT. Nothing was touched."
  fi
fi

say "The forge now"
helm --kube-context "$CONTEXT" -n "$FORGE_NS" status "$RELEASE" >/dev/null 2>&1 \
  || die "no forge release $RELEASE in $FORGE_NS on $CONTEXT. This upgrades a forge bootstrap-forge installed; it installs nothing."
HAVE_IMAGE="$(kubectl "${K[@]}" -n "$FORGE_NS" get deploy "$RELEASE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="forgejo")].image}' 2>/dev/null || true)"
[[ -n "$HAVE_IMAGE" ]] || die "cannot read the forge's image from deploy/$RELEASE in $FORGE_NS"
HAVE_TAG="${HAVE_IMAGE##*:}"; HAVE_TAG="${HAVE_TAG%%@*}"
info "running ${HAVE_IMAGE}; this release pins chart ${PIN_CHART}, Forgejo ${PIN_IMAGE}"
if [[ "$HAVE_TAG" == "$PIN_IMAGE"* ]]; then
  ok "the forge already runs the pinned Forgejo ${PIN_IMAGE}; nothing to do. Move the Tockmox pin next."
  exit 0
fi
major() { printf '%s' "${1%%.*}"; }
if [[ "$(major "$HAVE_TAG")" != "$(major "$PIN_IMAGE")" ]]; then
  warn "this is a Forgejo MAJOR upgrade (${HAVE_TAG} to ${PIN_IMAGE}). The release notes name it in their first section;"
  warn "read them before you go on. A major moves only in a Tockmox minor."
fi

say "A fresh off-site copy"
COPY="${RELEASE}-offsite"
COPY_TXT=""
if kubectl "${K[@]}" -n "$FORGE_NS" get cronjob "$COPY" >/dev/null 2>&1; then
  if $DRY_RUN; then
    info "would run a copy now (job from cronjob/$COPY) and wait for it to succeed"
  else
    JOB="${COPY}-preupgrade-$(date -u +%H%M%S)"
    kubectl "${K[@]}" -n "$FORGE_NS" create job "$JOB" --from="cronjob/$COPY" >/dev/null \
      || die "could not start a copy job from cronjob/$COPY. Nothing was upgraded."
    kubectl "${K[@]}" -n "$FORGE_NS" wait --for=condition=complete "job/$JOB" --timeout=300s >/dev/null 2>&1 \
      || die "the off-site copy before the upgrade did not succeed: $(kubectl "${K[@]}" -n "$FORGE_NS" logs "job/$JOB" 2>/dev/null | tail -1)
       Nothing was upgraded. Fix the copy (TockmoxSiteRepositoryCopyBehind names why), then run this again."
    COPY_TXT="$(kubectl "${K[@]}" -n "$FORGE_NS" logs "job/$JOB" 2>/dev/null | tail -1)"
    ok "off-site copy: ${COPY_TXT:-written and read back}"
  fi
elif $WITHOUT_COPY; then
  warn "no off-site copy on this site (no cronjob/$COPY), and --without-copy was given: a failed upgrade"
  warn "has nothing to be repaired from but whatever copy you keep yourself."
else
  die "this site has no off-site copy (no cronjob/$COPY in $FORGE_NS), so a failed upgrade could not be repaired.
       Give it a destination first (re-run bootstrap-forge with --offsite-s3-* or --offsite-git), or pass
       --without-copy if you accept that. Nothing was upgraded."
fi

say "The upgrade"
if $DRY_RUN; then
  info "would run: helm upgrade $RELEASE $CHART_REF --version $PIN_CHART --reuse-values --set image.tag=$PIN_IMAGE (namespace $FORGE_NS)"
  info "then check the forge answers at Forgejo $PIN_IMAGE"
  exit 0
fi
REPAIR="tockmox-install.sh repair-forge --context $CONTEXT --restore-from offsite <the off-site flags> --kit-out NEW-KIT ..."
helm --kube-context "$CONTEXT" upgrade "$RELEASE" "$CHART_REF" --version "$PIN_CHART" -n "$FORGE_NS" \
  --reuse-values --set "image.tag=$PIN_IMAGE" --wait --timeout "${WAIT_SECONDS}s" >/dev/null \
  || die "the forge's upgrade to chart $PIN_CHART failed or did not become ready within ${WAIT_SECONDS}s.
       Look at: kubectl --context $CONTEXT -n $FORGE_NS get pods,events
       If it does not come back, repair it from the copy just taken:
         $REPAIR
       (docs/administration/site-forge-recovery.md, Repair only the forge). Do not move the Tockmox pin."
kubectl "${K[@]}" -n "$FORGE_NS" rollout status "deploy/$RELEASE" --timeout="${WAIT_SECONDS}s" >/dev/null \
  || die "the forge did not become ready within ${WAIT_SECONDS}s after the upgrade. If it does not, repair it:
         $REPAIR"
# The forge's own API, read from inside its pod: a version answer, not a download (nothing is run from it).
VERSION_API="http://127.0.0.1:3000/api/v1/version"
ANSWER="$(kubectl "${K[@]}" -n "$FORGE_NS" exec "deploy/$RELEASE" -c forgejo -- \
  curl -sS --max-time 10 "$VERSION_API" 2>/dev/null || true)"
GOT="$(printf '%s' "$ANSWER" | sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p')"
[[ "$GOT" == "$PIN_IMAGE"* ]] || die "the forge answers as '${GOT:-nothing}', not Forgejo ${PIN_IMAGE}. Do not move the Tockmox pin.
       If it does not settle, repair it from the copy just taken:
         $REPAIR"
ok "the forge answers as Forgejo ${GOT} (was ${HAVE_TAG})"
info "next: move the site's Tockmox pin (docs/deployment/upgrade.md, 5. Move the revision)"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The identity and AI-layer seams a migrating site needs, asserted on the render
# (TM-0820, TM-0669).
#
#   ./tools/check-identity-seams.sh              render and assert
#   ./tools/check-identity-seams.sh --selftest   prove every assertion can go red
#
# WHAT IS ASSERTED, one line per seam:
#   S1  sso.apps.<app>.host moves the OIDC redirect URI AND the launch URL; at
#       the default they stay <prefix>.<internalDomain>. The Open WebUI host used
#       to be hard-coded `chat.`, so a site serving it elsewhere registered a
#       redirect URI Open WebUI never sent and got redirect_uri_mismatch.
#   S2  sso.subMode / sso.apps.<app>.subMode render `sub_mode` on the provider,
#       per-app winning; unset renders nothing (Authentik's own default); a
#       value Authentik does not know fails the render.
#   S3  sso.mergeAccountsByEmail drives OAUTH_MERGE_ACCOUNTS_BY_EMAIL, default
#       "true".
#   S4  modelGateway.database.recovery swaps initdb for bootstrap.recovery plus
#       an externalClusters entry; default renders initdb and none of it; the
#       two ways to get it wrong (no source, same archive path) fail the render.
#   S6  Grafana's OIDC role mapping sends tockmox-admins to GrafanaAdmin (server
#       admin) and everyone else to Viewer, and allow_assign_grafana_admin is
#       true, without which Grafana ignores GrafanaAdmin from role_attribute_path
#       and the mapping silently lands on org Admin. sso.adminGroup is followed.
#       The same file sets email_attribute_path to `email || preferred_username`
#       (TM-0667), so a user with no email claim ends Grafana's email lookup in
#       the claim and never reaches its GitHub-style `<api_url>/emails` request,
#       which Authentik answers with a 404 that fails the whole login.
#   S7  modelGateway.database.backup.enabled is the capability tri-state
#       (TM-0312): unset follows capabilities.dataProtection, so a stock render
#       carries the ObjectStore, the plugin wiring, the ScheduledBackup and the
#       restore drill and NOT the unbacked-database alert; false, or the
#       capability declined, drops all four and renders the alert instead; true
#       beats a declined capability; unbackedAlert: false silences the alert.
#   S8  sso.adminUsers: empty (the default) renders no admin-membership Job;
#       non-empty renders exactly one, an Argo PostSync hook that deletes the
#       previous Job before creating the next, running the SERVER's image with
#       its config Secret, non-root, no privilege escalation, every capability
#       dropped, a seccomp profile; it carries the usernames and sso.adminGroup;
#       sso.enabled=false or a username with whitespace renders none / fails
#       (TM-0820 A3); it waits for the system/bootstrap.yaml blueprint before
#       looking names up, or a fresh install reports akadmin not-found
#       (0.7.1-rc3 gate).
#   S9  the same list is ALSO an ordinary ConfigMap (tockmox-admin-users-list):
#       a hook is not in Argo's diff, so without it adding a name to a running
#       install starts no sync and the Job never runs (0.7.1-rc1 gate, L6). The
#       ConfigMap is no hook, carries the usernames and the group, changes when
#       the list changes, and is absent at the default.
#   S10 the bundled PostgreSQL server and the pg_dump client in the backup
#       CronJob run the same MAJOR (TM-1023). They are two pins: the server tag
#       comes from authentik's vendored subchart, the client is
#       databaseBackup.postgresImage. pg_dump refuses a server newer than itself,
#       and in a CronJob that refusal is a log line, so the nightly dump stops
#       and only the freshness alert says so.
#   S5  tools/mint-secrets.sh --only sso mints the four sso files and nothing
#       else, and refuses an unknown group.
#   S11 the Authentik worker restarts onto a changed blueprint (TM-1058). The
#       scripts the chart puts on the worker (postStart records a hash of
#       /blueprints/mounted, the liveness probe compares it) are EXTRACTED from the
#       render and RUN against a scratch mount: unchanged passes, an edited file in
#       any mounted directory, a new file, fails; a failing `ak healthcheck` still
#       fails; a missing baseline is recorded rather than failing. Read as text it
#       would pass a probe that never compares anything.
#   S12 the Authentik worker never runs beside its replacement (TM-1060). Its
#       Deployment renders a RollingUpdate with maxSurge 0 and maxUnavailable
#       100%: the old worker is gone before the new one starts, so the startup
#       discovery a new pod queues cannot be taken by an old worker that lacks
#       the blueprint. Not `type: Recreate`: Argo CD's ServerSideApply cannot
#       switch a live Deployment to it, and the upgrade would fail on the very
#       installs it is for.
#
# WHY RENDER TEXT AND NOT A VALUES DIFF. The failure each seam prevents is in
# what reaches Authentik, Open WebUI and CNPG, not in what values.yaml says. A
# key that is declared and never read passes every values check.
#
# S5 needs openssl and a stand-in `kubeseal` (written to a temp dir, never the
# real one) and no cluster.
set -uo pipefail
cd "$(dirname "$0")/.."

CI=ci/values.yaml
IDC=charts/tockmox-identity
AIC=charts/tockmox-ai
OBC=charts/tockmox-observability

if [ "${1:-}" != "--selftest" ] && ! command -v helm >/dev/null 2>&1; then
  echo "check-identity-seams: helm is not on PATH; refusing to report a tree it did not render" >&2
  exit 1
fi

FAILS=0
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
ok()   { echo "  ok   $*"; }

# has <file> <fixed-string>  /  lacks <file> <fixed-string>
# render_says <pattern> <helm args...>: the render must FAIL and say <pattern>.
# Captured first: `helm | grep -q` under pipefail reports helm's SIGPIPE, not grep.
render_says() { local pat="$1" out; shift; out=$(render "$@"); grep -q -- "$pat" <<<"$out"; }
has()   { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

# --- assertions over rendered files; each returns 0 (holds) or 1 -------------

# S1 a: default redirect and launch URL keep the prefix form.
s1_default() { has "$1" 'url: "https://chat.int.example.com/oauth/oidc/callback"' \
  && has "$1" 'meta_launch_url: "https://chat.int.example.com"' \
  && has "$1" 'url: "https://grafana.int.example.com/login/generic_oauth"'; }
# S1 b: override moves both, and the old host is gone for that app.
s1_override() { has "$1" 'url: "https://llm.int.example.com/oauth/oidc/callback"' \
  && has "$1" 'meta_launch_url: "https://llm.int.example.com"' \
  && lacks "$1" 'https://chat.int.example.com'; }
# S2 a: nothing rendered by default.
s2_default() { lacks "$1" 'sub_mode'; }
# S2 b: global user_username on all three, grafana overridden to user_email.
s2_values() { [ "$(grep -c 'sub_mode: user_username' "$1")" = 2 ] \
  && [ "$(grep -c 'sub_mode: user_email' "$1")" = 1 ]; }
# S3
s3_default() { has "$1" 'OAUTH_MERGE_ACCOUNTS_BY_EMAIL: "true"'; }
s3_off()     { has "$1" 'OAUTH_MERGE_ACCOUNTS_BY_EMAIL: "false"'; }
# S4
s4_default() { has "$1" 'initdb:' && lacks "$1" 'recovery:' && lacks "$1" 'externalClusters:' && lacks "$1" 'serverName'; }
s4_recovery() { has "$1" 'recovery:' && lacks "$1" 'initdb:' && has "$1" 'externalClusters:' \
  && has "$1" 'serverName: "tockmox-litellm-db"' && has "$1" 'serverName: "r1"' \
  && has "$1" 'source: "tockmox-litellm-db-origin"'; }
# S7: the whole AI chart, one render per case. The four objects that make a
# backup a backup, then the alert that stands in for them.
s7_backed() { has "$1" 'kind: ScheduledBackup' && has "$1" 'kind: ObjectStore' \
  && has "$1" 'barmanObjectName: "tockmox-litellm-db-store"' && has "$1" 'name: tockmox-litellm-db-drill' \
  && lacks "$1" 'TockmoxModelGatewayDatabaseUnbacked'; }
s7_unbacked() { lacks "$1" 'kind: ScheduledBackup' && lacks "$1" 'kind: ObjectStore' \
  && lacks "$1" 'barmanObjectName' && lacks "$1" 'name: tockmox-litellm-db-drill' \
  && has "$1" 'alert: TockmoxModelGatewayDatabaseUnbacked'; }
s7_quiet() { lacks "$1" 'TockmoxModelGatewayDatabaseUnbacked' && lacks "$1" 'kind: ScheduledBackup'; }
# S10: every postgres image in the identity render (server StatefulSet, pg_dump
# CronJob) has one major, and there are at least two of them to compare.
s10_majors() { local m; m=$(grep -Eo 'image: *"?[^ "]*/postgres(ql)?:[0-9]+' "$1" | sed -E 's/.*:([0-9]+)$/\1/' | sort)
  [ "$(printf '%s\n' "$m" | grep -c .)" -ge 2 ] && [ "$(printf '%s\n' "$m" | sort -u | grep -c .)" = 1 ]; }

# S6: the mapping and the setting that makes it effective.
s6_default() { has "$1" "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH: \"contains(groups[*], 'tockmox-admins') && 'GrafanaAdmin' || 'Viewer'\"" \
  && has "$1" 'GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN: "true"' \
  && has "$1" 'GF_AUTH_GENERIC_OAUTH_EMAIL_ATTRIBUTE_PATH: "email || preferred_username"' \
  && has "$1" 'GF_AUTH_GENERIC_OAUTH_LOGIN_ATTRIBUTE_PATH: "preferred_username"' \
  && lacks "$1" "&& 'Admin' ||"; }
s6_group()   { has "$1" "contains(groups[*], 'site-admins') && 'GrafanaAdmin'"; }

# S8: the admin-membership Job. $1 is the FULL identity render.
JOBN='tockmox-authentik-admin-users'
s8_default() { lacks "$1" "$JOBN" && lacks "$1" 'TOCKMOX_ADMIN_USERS'; }
# The Job's own YAML document, so a securityContext on the server cannot satisfy it.
s8_doc() { awk -v n="$JOBN" 'BEGIN{RS="\n---\n"} index($0, "\n  name: " n "\n") {print}' "$1"; }
s8_on() { local d; d=$(s8_doc "$1"); [ "$(grep -c "^  name: $JOBN\$" <<<"$d")" = 1 ] \
  && has <(echo "$d") 'value: "alice bob"' && has <(echo "$d") 'value: "tockmox-admins"' \
  && has <(echo "$d") 'argocd.argoproj.io/hook: PostSync' \
  && has <(echo "$d") 'argocd.argoproj.io/hook-delete-policy: BeforeHookCreation' \
  && has <(echo "$d") 'runAsNonRoot: true' \
  && has <(echo "$d") 'allowPrivilegeEscalation: false' && has <(echo "$d") 'capabilities: { drop: ["ALL"] }' \
  && has <(echo "$d") 'seccompProfile: { type: RuntimeDefault }' \
  && [ "$(grep -o 'image: ghcr.io/goauthentik/server:[^ ]*' "$1" | sort -u | wc -l | tr -d ' ')" = 1 ] \
  && has <(echo "$d") "$(awk 'BEGIN{RS="\n---\n"} /kind: Deployment/ && /component: "server"/ {print}' "$1" | grep -o 'image: ghcr.io/goauthentik/server:[^ ]*' | head -1)" \
  && has <(echo "$d") 'name: t-authentik' \
  && has <(echo "$d") 'BlueprintInstance.objects.filter(path="system/bootstrap.yaml")'; }
s8_group() { has "$1" 'value: "site-admins"' && lacks "$1" 'value: "tockmox-admins"'; }
# S9: the list as a compared resource. The ConfigMap's own document.
CMN='tockmox-admin-users-list'
s9_doc() { awk -v n="$CMN" 'BEGIN{RS="\n---\n"} index($0, "\n  name: " n "\n") {print}' "$1"; }
s9_default() { lacks "$1" "$CMN"; }
s9_on() { local d; d=$(s9_doc "$1"); [ -n "$d" ] && has <(echo "$d") 'kind: ConfigMap' \
  && lacks <(echo "$d") 'argocd.argoproj.io/hook' \
  && has <(echo "$d") 'users: "alice bob"' && has <(echo "$d") 'group: "tockmox-admins"'; }
# The list changing must change the compared object, or the sync never starts.
s9_moves() { [ "$(s9_doc "$1")" != "$(s9_doc "$2")" ]; }

# S11: the worker's restart-on-blueprint-change scripts, run for real. $1 is the
# FULL identity render. The scripts are lifted out of the worker Deployment's own
# YAML document (never from values.yaml, so what is tested is what is deployed) and
# pointed at a scratch directory by rewriting the two paths they use.
s11_doc() { awk 'BEGIN{RS="\n---\n"} /kind: Deployment/ && /component: "?worker"?/ {print}' "$1"; }
s11_probe() {
  local d t rc=0; d=$(s11_doc "$1"); [ -n "$d" ] || return 1
  t=$(mktemp -d)
  printf '%s\n' "$d" | python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin); t = sys.argv[1]
c = d["spec"]["template"]["spec"]["containers"][0]
post = c["lifecycle"]["postStart"]["exec"]["command"]
live = c["livenessProbe"]["exec"]["command"]
assert post[:2] == ["/bin/sh", "-c"] and live[:2] == ["/bin/sh", "-c"]
open(t + "/post.sh", "w").write(post[2]); open(t + "/live.sh", "w").write(live[2])
' "$t" 2>/dev/null || { rm -rf "$t"; return 1; }
  mkdir -p "$t/m/cm-a" "$t/m/cm-b" "$t/bin"
  echo one > "$t/m/cm-a/a.yaml"; echo two > "$t/m/cm-b/b.yaml"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/ak"; chmod +x "$t/bin/ak"
  command -v sha256sum >/dev/null 2>&1 || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$t/bin/sha256sum"; chmod +x "$t/bin/sha256sum"; }   # macOS has shasum, not sha256sum
  local f; for f in post live; do
    sed -e "s#/blueprints/mounted#$t/m#g" -e "s#/tmp/.blueprints-at-start#$t/start#g" "$t/$f.sh" > "$t/$f.run"
  done
  run() { PATH="$t/bin:$PATH" /bin/sh "$t/$1.run" >/dev/null 2>&1; }
  run post                                                          || rc=1   # baseline recorded
  run live                                                          || rc=1   # unchanged: healthy
  echo three > "$t/m/cm-b/b.yaml";   run live && rc=1                          # edited, second directory: must fail
  echo two > "$t/m/cm-b/b.yaml";     run live                       || rc=1   # put back: healthy again
  echo new > "$t/m/cm-a/c.yaml";     run live && rc=1                          # a new file: must fail
  rm -f "$t/m/cm-a/c.yaml";          run live                       || rc=1
  rm -f "$t/start";                  run live                       || rc=1   # no baseline: record it, do not fail
  [ -s "$t/start" ]                                                 || rc=1
  printf '#!/bin/sh\nexit 1\n' > "$t/bin/ak"; run live && rc=1               # ak healthcheck failing still fails
  rm -rf "$t"; return $rc
}

# S12: the worker Deployment's strategy, read from its own YAML document.
s12_strategy() {
  local d; d=$(s11_doc "$1"); [ -n "$d" ] || return 1
  printf '%s\n' "$d" | python3 -c '
import sys, yaml
s = yaml.safe_load(sys.stdin)["spec"].get("strategy") or {}
ru = s.get("rollingUpdate") or {}
sys.exit(0 if s.get("type") == "RollingUpdate" and str(ru.get("maxSurge")) == "0" and ru.get("maxUnavailable") == "100%" else 1)
' 2>/dev/null
}

# --- the render ---------------------------------------------------------------
render() { helm template t "$@" 2>&1; }

DB=(-f $CI --set apps.litellm.enabled=true --set modelGateway.database.backup.enabled=true)
REC=(--set modelGateway.database.backup.serverName=r1 --set modelGateway.database.recovery.enabled=true --set modelGateway.database.recovery.serverName=tockmox-litellm-db)

# S5: --only sso. Prints the file names minted, one per line, or the rc line.
mint_only() { # <group-list> <outdir>
  local bin cert
  bin=$(mktemp -d); cert="$bin/cert.pem"; echo x > "$cert"
  printf '#!/bin/sh\ncat >/dev/null; echo "kind: SealedSecret"\n' > "$bin/kubeseal"; chmod +x "$bin/kubeseal"
  PATH="$bin:$PATH" bash tools/mint-secrets.sh --cert "$cert" --out "$2" --no-prompt --no-next -y --only "$1" >/dev/null 2>&1
  local rc=$?
  ls "$2" 2>/dev/null | sort | tr '\n' ' '
  echo "rc=$rc"
  rm -rf "$bin"
}
SSO_FILES="sso-argo.sealed.yaml sso-grafana.sealed.yaml sso-openwebui.sealed.yaml sso.sealed.yaml rc=0"

run_checks() {
  local t; t=$(mktemp -d)
  render $IDC -f $CI -s templates/sso-blueprints.yaml > "$t/id-default"
  render $IDC -f $CI -s templates/sso-blueprints.yaml --set sso.apps.openWebui.host=llm.int.example.com > "$t/id-host"
  render $IDC -f $CI -s templates/sso-blueprints.yaml --set sso.subMode=user_username --set sso.apps.grafana.subMode=user_email > "$t/id-sub"
  render $AIC -f $CI -s templates/sso-env.yaml > "$t/ai-default"
  render $AIC -f $CI -s templates/sso-env.yaml --set sso.mergeAccountsByEmail=false > "$t/ai-merge-off"
  render $AIC "${DB[@]}" -s templates/litellm-db.yaml > "$t/db-default"
  render $AIC "${DB[@]}" "${REC[@]}" -s templates/litellm-db.yaml > "$t/db-rec"
  render $AIC -f $CI > "$t/ai-stock"
  render $AIC -f $CI --set modelGateway.database.backup.enabled=false > "$t/ai-bk-false"
  render $AIC -f $CI --set capabilities.dataProtection.enabled=false > "$t/ai-cap-off"
  render $AIC -f $CI --set capabilities.dataProtection.enabled=false --set modelGateway.database.backup.enabled=true > "$t/ai-cap-off-true"
  render $AIC -f $CI --set modelGateway.database.backup.enabled=false --set modelGateway.database.backup.unbackedAlert=false > "$t/ai-quiet"
  render $OBC -f $CI -s templates/sso-env.yaml > "$t/ob-default"
  render $OBC -f $CI -s templates/sso-env.yaml --set sso.adminGroup=site-admins > "$t/ob-group"
  render $IDC -f $CI > "$t/s8-default"
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob}' > "$t/s8-on"
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob}' --set sso.adminGroup=site-admins > "$t/s8-group"
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob}' --set sso.enabled=false > "$t/s8-off"
  s11_probe "$t/s8-default"   && ok "S11 the worker's postStart and liveness scripts restart it onto a changed or new blueprint in any mounted directory, and still fail on a failing healthcheck" || fail "S11 the worker does not restart onto a changed blueprint"
  s12_strategy "$t/s8-default" && ok "S12 the worker rolls with maxSurge 0 and maxUnavailable 100%, so an old worker never takes the new pod's blueprint discovery" || fail "S12 the worker can run beside its replacement during a rollout"
  s8_default "$t/s8-default"  && ok "S8 sso.adminUsers empty renders no admin-membership Job" || fail "S8 Job rendered at the default"
  s10_majors "$t/s8-default"  && ok "S10 the bundled PostgreSQL server and the pg_dump client run one major ($(grep -Eo 'image: *"?[^ "]*/postgres(ql)?:[0-9.]+' "$t/s8-default" | sed -E 's/.*://' | sort -u | tr '\n' ' '))" || fail "S10 server and pg_dump client majors differ, or one of them is missing: $(grep -Eo 'image: *"?[^ "]*/postgres(ql)?:[^ "]+' "$t/s8-default" | sort -u | tr '\n' ' ')"
  s8_on "$t/s8-on"            && ok "S8 sso.adminUsers renders one PostSync Job: usernames, server image and Secret, restricted securityContext" || fail "S8 Job shape wrong"
  s8_group "$t/s8-group"      && ok "S8 sso.adminGroup is the group the Job targets" || fail "S8 adminGroup not followed"
  s8_default "$t/s8-off"      && ok "S8 sso.enabled=false renders no Job" || fail "S8 Job rendered with sso off"
  if render_says "does not match pattern" $IDC -f $CI --set 'sso.adminUsers={"a b"}'; then ok "S8 a username with whitespace fails the render"; else fail "S8 whitespace username accepted"; fi
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob,carol}' > "$t/s9-more"
  s9_default "$t/s8-default"  && ok "S9 sso.adminUsers empty renders no admin-list ConfigMap" || fail "S9 ConfigMap rendered at the default"
  s9_on "$t/s8-on"            && ok "S9 the list is also an ordinary ConfigMap (no hook) with the usernames and the group" || fail "S9 ConfigMap missing, a hook, or not carrying the list"
  s9_moves "$t/s8-on" "$t/s9-more" && ok "S9 adding a name changes the compared ConfigMap, so a running install syncs" || fail "S9 adding a name changes nothing Argo compares"
  s7_backed "$t/ai-stock"     && ok "S7 a stock render (backup.enabled unset) carries ObjectStore, plugin, ScheduledBackup and drill, no unbacked alert" || fail "S7 stock render is not backed up"
  s7_unbacked "$t/ai-bk-false" && ok "S7 backup.enabled=false drops all four and renders TockmoxModelGatewayDatabaseUnbacked" || fail "S7 explicit false wrong"
  s7_unbacked "$t/ai-cap-off" && ok "S7 declining dataProtection turns the unset default off, with the alert" || fail "S7 capability decline not followed"
  s7_backed "$t/ai-cap-off-true" && ok "S7 backup.enabled=true beats a declined capability" || fail "S7 explicit true did not override"
  s7_quiet "$t/ai-quiet"      && ok "S7 backup.unbackedAlert=false silences the alert" || fail "S7 unbackedAlert=false not followed"
  s6_default "$t/ob-default"  && ok "S6 tockmox-admins maps to GrafanaAdmin, others Viewer, allow_assign_grafana_admin true, email_attribute_path falls back to the username" || fail "S6 Grafana role mapping wrong"
  s6_group "$t/ob-group"      && ok "S6 sso.adminGroup is the group that maps to GrafanaAdmin" || fail "S6 adminGroup not followed"
  s1_default "$t/id-default"  && ok "S1 default redirect and launch URLs keep the <prefix>.<domain> form" || fail "S1 default hosts changed"
  s1_override "$t/id-host"    && ok "S1 sso.apps.openWebui.host moves redirect URI and launch URL" || fail "S1 host override not followed"
  s2_default "$t/id-default"  && ok "S2 no sub_mode rendered by default" || fail "S2 sub_mode rendered at default"
  s2_values "$t/id-sub"       && ok "S2 sso.subMode applies, per-app subMode wins" || fail "S2 sub_mode values not rendered as set"
  if render_says "must be one of" $IDC -f $CI --set sso.apps.argoWorkflows.subMode=bogus; then ok "S2 an unknown sub_mode fails the render"; else fail "S2 unknown sub_mode accepted"; fi
  s3_default "$t/ai-default"  && ok "S3 OAUTH_MERGE_ACCOUNTS_BY_EMAIL defaults to \"true\"" || fail "S3 default not true"
  s3_off "$t/ai-merge-off"    && ok "S3 sso.mergeAccountsByEmail=false renders \"false\"" || fail "S3 value not followed"
  s4_default "$t/db-default"  && ok "S4 default bootstrap is initdb, no recovery, no serverName" || fail "S4 default changed"
  s4_recovery "$t/db-rec"     && ok "S4 recovery renders bootstrap.recovery + externalClusters + both server names" || fail "S4 recovery render wrong"
  if render_says "nothing to recover from" $AIC "${DB[@]}" --set modelGateway.database.recovery.enabled=true; then ok "S4 recovery with no source fails the render"; else fail "S4 recovery with no source rendered"; fi
  if render_says "refuses to archive" $AIC "${DB[@]}" --set modelGateway.database.recovery.enabled=true --set modelGateway.database.recovery.serverName=tockmox-litellm-db; then ok "S4 recovery into its own archive path fails the render"; else fail "S4 same-archive guard missing"; fi
  local o; o=$(mint_only sso "$t/m1")
  [ "$o" = "$SSO_FILES" ] && ok "S5 mint-secrets --only sso mints the four sso files and nothing else" || fail "S5 --only sso minted: $o"
  o=$(mint_only bogus "$t/m2")
  case "$o" in *"rc=2") ok "S5 mint-secrets --only refuses an unknown group" ;; *) fail "S5 unknown group accepted: $o" ;; esac
  rm -rf "$t"
}

# --- selftest: break each assertion's input and require RED -------------------
selftest() {
  local t; t=$(mktemp -d); local bad=0
  red() { # name, command that must FAIL
    if "${@:2}" 2>/dev/null; then echo "  FAIL selftest: $1 passed on a broken render"; bad=1; else echo "  ok   $1 goes red"; fi
  }
  # Good renders first, so a mutation is the ONLY difference.
  render $IDC -f $CI -s templates/sso-blueprints.yaml > "$t/id"
  render $IDC -f $CI -s templates/sso-blueprints.yaml --set sso.apps.openWebui.host=llm.int.example.com > "$t/idh"
  render $IDC -f $CI -s templates/sso-blueprints.yaml --set sso.subMode=user_username --set sso.apps.grafana.subMode=user_email > "$t/ids"
  render $AIC -f $CI -s templates/sso-env.yaml > "$t/ai"
  render $AIC "${DB[@]}" -s templates/litellm-db.yaml > "$t/db"
  render $AIC "${DB[@]}" "${REC[@]}" -s templates/litellm-db.yaml > "$t/dbr"
  render $AIC -f $CI > "$t/ai7"
  render $AIC -f $CI --set modelGateway.database.backup.enabled=false > "$t/ai7off"
  render $AIC -f $CI --set modelGateway.database.backup.enabled=false --set modelGateway.database.backup.unbackedAlert=false > "$t/ai7q"
  render $OBC -f $CI -s templates/sso-env.yaml > "$t/ob"
  render $OBC -f $CI -s templates/sso-env.yaml --set sso.adminGroup=site-admins > "$t/obg"
  render $IDC -f $CI > "$t/s8d"
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob}' > "$t/s8"
  render $IDC -f $CI --set 'sso.adminUsers={alice,bob}' --set sso.adminGroup=site-admins > "$t/s8g"
  # The unmutated inputs must pass, or "red" below proves nothing.
  s1_default "$t/id" && s1_override "$t/idh" && s2_default "$t/id" && s2_values "$t/ids" && s3_default "$t/ai" \
    && s8_default "$t/s8d" && s11_probe "$t/s8d" && s12_strategy "$t/s8d" && s10_majors "$t/s8d" && s8_on "$t/s8" && s8_group "$t/s8g" && s9_default "$t/s8d" && s9_on "$t/s8" \
    && s4_default "$t/db" && s4_recovery "$t/dbr" && s6_default "$t/ob" && s6_group "$t/obg" && s7_backed "$t/ai7" && s7_unbacked "$t/ai7off" && s7_quiet "$t/ai7q" || { echo "selftest: the unmutated renders do not pass; fix the tree first"; rm -rf "$t"; return 1; }
  # S1: the old behaviour, host ignored.
  sed 's#https://llm.int.example.com#https://chat.int.example.com#g' "$t/idh" > "$t/m"; red "S1 host override ignored" s1_override "$t/m"
  sed 's#https://chat.int.example.com#https://llm.int.example.com#g' "$t/id" > "$t/m"; red "S1 default host changed" s1_default "$t/m"
  # S2: a sub_mode where none was set; and one dropped where set.
  { cat "$t/id"; echo "          sub_mode: user_username"; } > "$t/m"; red "S2 sub_mode at default" s2_default "$t/m"
  sed 's/sub_mode: user_email/sub_mode: user_username/' "$t/ids" > "$t/m"; red "S2 per-app precedence lost" s2_values "$t/m"
  # S3
  sed 's/OAUTH_MERGE_ACCOUNTS_BY_EMAIL: "true"/OAUTH_MERGE_ACCOUNTS_BY_EMAIL: "false"/' "$t/ai" > "$t/m"; red "S3 default flipped" s3_default "$t/m"
  # S4
  sed 's/initdb:/recovery:/' "$t/db" > "$t/m"; red "S4 default became recovery" s4_default "$t/m"
  grep -v 'externalClusters:' "$t/dbr" > "$t/m"; red "S4 externalClusters dropped" s4_recovery "$t/m"
  sed 's/serverName: "r1"/serverName: "x"/' "$t/dbr" > "$t/m"; red "S4 backup serverName dropped" s4_recovery "$t/m"
  # S6: the old mapping (org Admin); the setting dropped; the group name ignored.
  sed "s/&& 'GrafanaAdmin' ||/\&\& 'Admin' ||/" "$t/ob" > "$t/m"; red "S6 mapping back to org Admin" s6_default "$t/m"
  sed 's/ALLOW_ASSIGN_GRAFANA_ADMIN: "true"/ALLOW_ASSIGN_GRAFANA_ADMIN: "false"/' "$t/ob" > "$t/m"; red "S6 allow_assign_grafana_admin off" s6_default "$t/m"
  sed "s/'site-admins'/'tockmox-admins'/" "$t/obg" > "$t/m"; red "S6 adminGroup ignored" s6_group "$t/m"
  # S6 (TM-0667): the email fallback dropped; weakened to the bare claim.
  grep -v 'EMAIL_ATTRIBUTE_PATH' "$t/ob" > "$t/m"; red "S6 email_attribute_path dropped" s6_default "$t/m"
  sed 's/email || preferred_username/email/' "$t/ob" > "$t/m"; red "S6 email_attribute_path has no username fallback" s6_default "$t/m"
  # S7 (TM-0312): rendered text first, then a REAL mutation of the helper.
  grep -v 'kind: ScheduledBackup' "$t/ai7" > "$t/m"; red "S7 ScheduledBackup dropped from a stock render" s7_backed "$t/m"
  sed 's/barmanObjectName/barmanObjectNam/' "$t/ai7" > "$t/m"; red "S7 plugin wiring dropped" s7_backed "$t/m"
  sed 's/name: tockmox-litellm-db-drill/name: x/' "$t/ai7" > "$t/m"; red "S7 restore drill dropped" s7_backed "$t/m"
  { cat "$t/ai7"; echo "alert: TockmoxModelGatewayDatabaseUnbacked"; } > "$t/m"; red "S7 alert rendered while backed up" s7_backed "$t/m"
  grep -v 'alert: TockmoxModelGatewayDatabaseUnbacked' "$t/ai7off" > "$t/m"; red "S7 off renders no alert" s7_unbacked "$t/m"
  { cat "$t/ai7off"; echo "kind: ScheduledBackup"; } > "$t/m"; red "S7 off still schedules a backup" s7_unbacked "$t/m"
  { cat "$t/ai7q"; echo "alert: TockmoxModelGatewayDatabaseUnbacked"; } > "$t/m"; red "S7 unbackedAlert=false still alerts" s7_quiet "$t/m"
  # The default itself, mutated in the chart (a copy, never the tree): the helper
  # ignores the capability, which is the old `false` default in new clothes.
  mkdir -p "$t/mut"; cp -r "$AIC" "$t/mut/tockmox-ai"
  # Through the same copy, unmutated: a chart that will not render where it was copied to
  # (a dependency left behind, a missing charts/) would read below as a mutation going red.
  render "$t/mut/tockmox-ai" -f $CI > "$t/c"; s7_backed "$t/c" || { echo "selftest: the unmutated copy of $AIC does not render and pass; fix the tree first"; rm -rf "$t"; return 1; }
  # Write and move, not bare `sed -i`: BSD sed reads -i's next argument as a suffix (TM-0996).
  sed 's/"override" \.Values\.modelGateway\.database\.backup\.enabled/"override" false/' "$t/mut/tockmox-ai/templates/_backup.tpl" > "$t/mut/_backup.tpl" && mv "$t/mut/_backup.tpl" "$t/mut/tockmox-ai/templates/_backup.tpl"
  render "$t/mut/tockmox-ai" -f $CI > "$t/m"; red "S7 chart default pinned off (helper mutated)" s7_backed "$t/m"
  # S8: a Job at the default; the hook gone; the delete policy gone; run as root;
  # privilege escalation allowed; capabilities kept; a different image from the
  # server's; a name dropped; the group ignored; the config Secret dropped.
  { cat "$t/s8d"; echo "name: $JOBN"; } > "$t/m"; red "S8 Job at default" s8_default "$t/m"
  sed 's/argocd.argoproj.io\/hook: PostSync/argocd.argoproj.io\/hook: Sync/' "$t/s8" > "$t/m"; red "S8 hook is not PostSync" s8_on "$t/m"
  grep -v 'hook-delete-policy' "$t/s8" > "$t/m"; red "S8 delete policy dropped" s8_on "$t/m"
  sed 's/runAsNonRoot: true/runAsNonRoot: false/' "$t/s8" > "$t/m"; red "S8 Job runs as root" s8_on "$t/m"
  sed 's/allowPrivilegeEscalation: false/allowPrivilegeEscalation: true/' "$t/s8" > "$t/m"; red "S8 privilege escalation allowed" s8_on "$t/m"
  sed 's/capabilities: { drop: \["ALL"\] }/capabilities: { add: ["NET_ADMIN"] }/' "$t/s8" > "$t/m"; red "S8 capabilities not dropped" s8_on "$t/m"
  sed 's/seccompProfile: { type: RuntimeDefault }/seccompProfile: { type: Unconfined }/' "$t/s8" > "$t/m"; red "S8 seccomp profile dropped" s8_on "$t/m"
  awk -v n="$JOBN" '$0 ~ "^  name: " n "$" {f=1} f && /image: ghcr.io\/goauthentik\/server:/ && !d {sub(/server:.*/,"server:0.0.1"); d=1} {print}' "$t/s8" > "$t/m"; red "S8 Job image differs from the server's" s8_on "$t/m"
  sed 's/value: "alice bob"/value: "alice"/' "$t/s8" > "$t/m"; red "S8 a username dropped" s8_on "$t/m"
  grep -v 'path="system/bootstrap.yaml"' "$t/s8" > "$t/m"; red "S8 Job no longer waits for the bootstrap blueprint" s8_on "$t/m"
  sed 's/value: "site-admins"/value: "tockmox-admins"/' "$t/s8g" > "$t/m"; red "S8 adminGroup ignored" s8_group "$t/m"
  # S9: the ConfigMap gone (the rc1 shape); made a hook; the list dropped from it;
  # a list change that no longer reaches it.
  awk -v n="$CMN" 'BEGIN{RS="\n---\n"; ORS="\n---\n"} !index($0, "\n  name: " n "\n")' "$t/s8" > "$t/m"; red "S9 ConfigMap removed" s9_on "$t/m"
  awk -v n="$CMN" 'BEGIN{RS="\n---\n"; ORS="\n---\n"} index($0, "\n  name: " n "\n") {sub(/\n  labels:/, "\n  annotations:\n    argocd.argoproj.io/hook: PostSync\n  labels:")} {print}' "$t/s8" > "$t/m"; red "S9 ConfigMap made a hook" s9_on "$t/m"
  sed 's/users: "alice bob"/users: ""/' "$t/s8" > "$t/m"; red "S9 ConfigMap lost the usernames" s9_on "$t/m"
  red "S9 a list change that does not reach the ConfigMap" s9_moves "$t/s8" "$t/s8"
  { cat "$t/s8d"; echo "name: $CMN"; } > "$t/m"; red "S9 ConfigMap at default" s9_default "$t/m"
  # S10: the client moved a major alone (the Renovate PR the hold exists to stop); the client gone.
  render $IDC -f $CI --set databaseBackup.postgresImage=docker.io/library/postgres:18.6-bookworm > "$t/m"; red "S10 pg_dump client on 18, server on 17" s10_majors "$t/m"
  awk '/image: .*\/postgres:/ && !d {d=1; next} {print}' "$t/s8d" > "$t/m"; red "S10 only one postgres image left to compare" s10_majors "$t/m"
  # S11 (TM-1058): the comparison made unable to fail; the glob narrowed to one
  # directory; the content replaced by a listing; the healthcheck dropped; the
  # probe removed. Each is a plausible edit, each must leave the probe unable to
  # do its job.
  sed 's/^\( *\)exit 1$/\1exit 0/' "$t/s8d" > "$t/m"; red "S11 liveness probe never fails on a change" s11_probe "$t/m"
  sed 's#/blueprints/mounted/\*/\*#/blueprints/mounted/cm-tockmox-sso-blueprints/*#g' "$t/s8d" > "$t/m"; red "S11 only one mounted directory watched" s11_probe "$t/m"
  sed 's#cat /blueprints/mounted#ls /blueprints/mounted#g' "$t/s8d" > "$t/m"; red "S11 file names hashed, not content" s11_probe "$t/m"
  sed 's/ak healthcheck || exit 1/true/' "$t/s8d" > "$t/m"; red "S11 the healthcheck dropped from the probe" s11_probe "$t/m"
  sed '/ak healthcheck || exit 1/,/^ *fi$/d' "$t/s8d" > "$t/m"; red "S11 liveness script gone" s11_probe "$t/m"
  # S12 (TM-1060): the default surge back; the number loosened; the rolling
  # numbers gone; the type switched to the one Argo CD cannot apply.
  sed '/component: "*worker"*/,$ s/maxSurge: 0/maxSurge: 1/' "$t/s8d" > "$t/m"; red "S12 worker surges a new pod beside the old one" s12_strategy "$t/m"
  sed '/component: "*worker"*/,$ s/maxUnavailable: 100%/maxUnavailable: 0/' "$t/s8d" > "$t/m"; red "S12 worker never lets the old pod go first" s12_strategy "$t/m"
  sed '/component: "*worker"*/,$ s/type: RollingUpdate/type: Recreate/' "$t/s8d" > "$t/m"; red "S12 worker strategy switched to Recreate" s12_strategy "$t/m"
  # S5: the mint script with --only neutered must mint extra files. Run a mutated copy.
  mkdir -p "$t/tools"; sed 's/^want() {.*$/want() { return 0; }/' tools/mint-secrets.sh > "$t/tools/mint-secrets.sh"
  local bin; bin=$(mktemp -d); echo x > "$bin/cert.pem"
  printf '#!/bin/sh\ncat >/dev/null; echo "kind: SealedSecret"\n' > "$bin/kubeseal"; chmod +x "$bin/kubeseal"
  PATH="$bin:$PATH" bash "$t/tools/mint-secrets.sh" --cert "$bin/cert.pem" --out "$t/mo" --no-prompt --no-next -y --only sso >/dev/null 2>&1
  local mrc=$? sf miss=0
  # Red for the right reason: the copy ran to the end (exit 0) and minted the four sso files AND others.
  # A copy that crashed mints fewer files, which also differs from SSO_FILES and would have passed.
  for sf in ${SSO_FILES% rc=0}; do [ -e "$t/mo/$sf" ] || miss=1; done
  if [ "$mrc" = 0 ] && [ "$miss" = 0 ] && [ "$(ls "$t/mo" 2>/dev/null | wc -l)" -gt 4 ]; then echo "  ok   S5 --only neutered goes red"; else echo "  FAIL selftest: S5 --only neutered did not mint the sso files plus others (exit $mrc, $(ls "$t/mo" 2>/dev/null | wc -l) files)"; bad=1; fi
  rm -rf "$bin" "$t"
  [ "$bad" -eq 0 ] && echo "selftest: every assertion can go red" || echo "selftest: FAILED" >&2
  return "$bad"
}

if [ "${1:-}" = "--selftest" ]; then
  command -v helm >/dev/null 2>&1 || { echo "check-identity-seams: --selftest needs helm to produce the good renders" >&2; exit 1; }
  selftest; exit $?
fi

run_checks
if [ "$FAILS" -ne 0 ]; then echo "check-identity-seams: $FAILS failure(s)" >&2; exit 1; fi
echo "check-identity-seams: PASSED"

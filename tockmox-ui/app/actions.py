# SPDX-License-Identifier: Apache-2.0
"""Actions from the console (specs/tockmox-ui/SPEC.md section 7 in the planning repo).

What the UI and the tockmox-actions service share: the kinds, how an intent is written down, the nonce that binds a
sign-in to exactly one intent, and the checks both sides run. The UI stays write-free: it posts an intent to the
separate tockmox-actions service (app/actions_service.py), which holds the narrow credentials and does the work.

ONE INTENT, ONE SIGN-IN. Every action, low risk or not, goes through the identity provider on its way: the UI sends
the browser to the issuer with `nonce = nonce_for(intent)` (and `max_age` for a step-up kind), and hands the ID
token that comes back to the service with the intent. The service checks the token itself (issuer, audience, expiry,
the admin group, the nonce, and auth_time for a step-up kind), so a token authorizes that intent and no other, and a
UI pod that is not handed a person's browser cannot act. With a live identity-provider session the round trip is a
redirect the person does not see; for sync and restart it asks for a fresh sign-in when the last was over five
minutes ago.

Kinds (`actions.<kind>.enabled`; off means absent, never a disabled button):
  silence     silence a part's firing alerts for 1h, 4h, 24h (at most 7 days), reason required; expire it again
  runJob      a Job from an allowlisted CronJob, now
  argocd      refresh or sync an Argo CD application, through an account with get and sync only (the site's)
  restart     a rollout restart of an allowlisted Deployment or StatefulSet
  testAlert   one test alert down the same path as every other alert, to the phone
  identity    a recovery link for a person who is not an administrator, and membership of the user group, through a
              narrow Authentik service account; every one asks for a fresh sign-in
  changes     approve and apply, or decline, a change waiting on Platform > Changes, as the person's OWN forge identity
              (a second round trip, to the site's forge, whose sign-in is Authentik: the service exchanges its code
              for that person's token and uses it once), and revert an applied change by opening the opposite one as
              the change bot; those three ask for a fresh sign-in. Open a change a page renders (models, inference
              nodes) and add an administrator (sso.adminUsers, with a fresh sign-in) open one as the change bot, which
              waits for an approval like any other. No forge admin credential is used anywhere
  moveForge   Move to my own forge (Status > Site repository): check an empty repository elsewhere, move the site's
              whole history there and open the change that repoints Argo CD, then Finish once it is merged. Each run is
              bootstrap-forge's suspended <release>-move Job (install/forge-move.sh --in-cluster); the push credential
              goes to the service beside the intent, never in it, and from there only into the Job's own Secret
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import time
import uuid
from dataclasses import dataclass, field

# kind id -> (switch, risk, step-up, verb for Activity)
KINDS = {
    "silence": ("silence", "low", False, "Silenced"),
    "expire": ("silence", "low", False, "Expired a silence"),
    "run-job": ("runJob", "low", False, "Ran"),
    "refresh": ("argocd", "low", False, "Refreshed"),
    "sync": ("argocd", "medium", True, "Synced"),
    "restart": ("restart", "medium", True, "Restarted"),
    "test-alert": ("testAlert", "low", False, "Sent a test alert"),
    "recovery-link": ("identity", "medium", True, "Made a recovery link"),
    "add-member": ("identity", "medium", True, "Added to the user group"),
    "remove-member": ("identity", "medium", True, "Removed from the user group"),
    "approve-change": ("changes", "medium", True, "Approved and applied"),
    "decline-change": ("changes", "medium", True, "Declined"),
    "revert-change": ("changes", "medium", True, "Opened a revert of"),
    "open-change": ("changes", "low", False, "Opened a change"),
    "add-admin": ("changes", "medium", True, "Opened a change adding an administrator"),
    "set-capability": ("changes", "low", False, "Opened a change setting"),
    "bump-release": ("changes", "medium", True, "Opened a change upgrading Tockmox"),
    "set-feature": ("changes", "low", False, "Opened a change setting"),
    "assign-job": ("changes", "low", False, "Opened a change giving"),
    "move-forge": ("moveForge", "high", True, "Moved the site repository"),
}
SWITCHES = ("silence", "runJob", "argocd", "restart", "testAlert", "identity", "changes", "moveForge")
IDENTITY_KINDS = ("recovery-link", "add-member", "remove-member")
CHANGE_KINDS = ("approve-change", "decline-change", "revert-change")
# The kinds that act as the person in the forge: the UI takes the browser to the forge's own sign-in after the
# identity provider's, and the service exchanges the code for that person's token. Revert opens a change as the bot,
# and that change waits for an approval like any other.
FORGE_PERSON_KINDS = ("approve-change", "decline-change")
# The kinds that OPEN a change as the change bot from a page that renders one; it waits for an approval like any other.
# open-change carries a draft the page staged with the service (its digest); add-admin is computed by the service from
# what main says now.
OPEN_KINDS = ("open-change", "add-admin", "set-capability", "bump-release", "set-feature", "assign-job")
DRAFT_WHATS = ("models", "nodes")
DIGEST = re.compile(r"[0-9a-f]{64}")
ADMIN_USERNAME = re.compile(r"[^\s\x00-\x1f\x7f]{1,150}")   # sso.adminUsers' own schema: no whitespace
VALUES_PATH = re.compile(r"([A-Za-z0-9_-][A-Za-z0-9._-]{0,99}/){0,9}[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}\.ya?ml")   # no segment starts with a dot
VALUES_FILES = {"models": "site/values/ai.yaml", "identity": "site/values/identity.yaml",
                "global": "site/values/global.yaml", "ai": "site/values/ai.yaml"}
# set-capability: the capability switches (docs/administration/capabilities.md), each in the file every layer reads.
# identity is the console's own sign-in, so the console never opens a change turning it OFF (that change would lock
# out the person approving it); it may turn it on.
CAPABILITIES = ("identity", "observability", "notifications", "aiPlane", "dataProtection", "hardwareTelemetry",
                "workflowAutomation", "networkPolicy")
NEVER_OFF_FROM_THE_CONSOLE = ("identity",)
# set-feature: the console's own optional areas, each one key in the AI layer's values (where tockmoxUi lives).
FEATURES = {"platform": ("Platform Management", ("tockmoxUi", "config", "features", "platform", "enabled"))}
# assign-job: scheduled work with no owner, given to a role by name in features.platform.assign (docs/administration/
# platform-management.md). A CronJob or CronWorkflow name, and a catalog role id (platform.py's own rule).
ASSIGN_PATH = ("tockmoxUi", "config", "features", "platform", "assign")
JOB_NAME = re.compile(r"[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?")
ROLE_ID = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
# bump-release: a release tag, as the installer writes it into each layer's Application (targetRevision: v0.8.3), and
# the preflight the Upgrade page drew, which the change carries in its description.
RELEASE_TAG = re.compile(r"v\d{1,4}\.\d{1,4}\.\d{1,4}(?:-[0-9A-Za-z.]{1,40})?")
BUMP_KINDS = ("patch", "minor", "major")
PREFLIGHT_STATES = ("ok", "critical", "warning", "unknown")
APPLICATIONS_FOLDER = "bootstrap/applications"
SHA = re.compile(r"[0-9a-f]{40}")
REPO = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")
RECOVERY_HOURS = (1, 24, 72)
# move-forge: check, move (steps 1 to 4) or finish (step 5), to an https repository with no credentials in its URL;
# a run is named for its Job (<release>-move-<mode>-<6 hex>), which the next step names as the one it follows.
MOVE_MODES = ("check", "move", "finish")
MOVE_TO = re.compile(r"https://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?/[A-Za-z0-9._~/-]{1,300}")
MOVE_JOB = re.compile(r"[a-z0-9-]{1,40}-move-(check|move|finish)-[0-9a-f]{6}")
MOVE_USER = re.compile(r"[A-Za-z0-9._@-]{1,100}")
MOVE_TOKEN = re.compile(r"[A-Za-z0-9!#$%&'()*+,./:;<=>?@^_`{|}~\[\]-]{1,400}")   # printable; no space, quote, backslash
# What may never be silenced: the alerts that prove the alert path works. Silencing one hides a dead pipeline.
NEVER_SILENCE = frozenset({"Watchdog", "TockmoxHeartbeat", "TockmoxSelfCheckStale", "InfoInhibitor"})
SILENCE_HOURS = (1, 4, 24)
MAX_SILENCE_HOURS = 168
CREATED_BY_SUFFIX = " (Tockmox UI)"          # how a silence this service made is told from one a person made
STEP_UP_MAX_AGE = 300

ALERTNAME = re.compile(r"[A-Za-z_:][A-Za-z0-9_:]{0,199}")
DNS_LABEL = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
DNS_NAME = re.compile(r"[a-z0-9]([-a-z0-9.]{0,251}[a-z0-9])?")
PART_ID = re.compile(r"[a-z0-9][-a-z0-9_]{0,62}")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
WORKLOAD_KINDS = ("Deployment", "StatefulSet")
USERNAME = re.compile(r"[^\x00-\x1f\x7f]{1,150}")   # Authentik's usernames: any text up to 150 (review D-4)
GROUP_NAME = re.compile(r"[^\s][^\n]{0,79}")


class Refused(ValueError):
    """An intent this side will not carry out, with the reason in words.

    `reason` is the sentence written at the raise site for a person to read, and the only part of a refusal that goes
    back to a caller. Text read from an upstream response never goes in it; that goes to the log."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = str(reason)


@dataclass(frozen=True)
class Config:
    """`actions:` in the UI's and the service's configuration."""
    url: str = ""                                  # the service, as the UI reaches it
    enabled: frozenset = frozenset()               # switches that are on
    jobs: tuple = ()                               # ((namespace, cronjob, part), ...); part "" = by namespace
    workloads: tuple = ()                          # ((namespace, kind, name, part), ...)
    argocd_url: str = ""                           # service side: the Argo CD API
    argocd_token_file: str = ""
    identity_api: str = ""                         # service side: Authentik's origin (the issuer's, by default)
    identity_token_file: str = ""
    user_group: str = "tockmox-users"              # the one group membership actions may change
    recovery_groups: tuple = ()                    # groups besides the user group a recoverable person may be in
    changes_api: str = ""                          # service side: the site forge's API, e.g. http://...:3000/api/v1
    changes_repo: str = ""                         # owner/name of the site repository
    changes_base: str = "main"
    changes_bot_token_file: str = ""               # service side: the change bot's token (reads, and opens reverts)
    changes_authorize_url: str = ""                # the forge's OAuth2 authorize URL, as a browser reaches it
    changes_token_url: str = ""                    # the forge's token endpoint, as the pod reaches it
    changes_client_id: str = ""                    # the console's OAuth2 application in the forge, inline or ...
    changes_client_id_file: str = ""               # ... from a file (bootstrap-forge writes it; the forge makes it up)
    changes_client_secret_file: str = ""           # service side only: the UI never holds it
    changes_web: str = ""                          # the forge's web origin, for "open in the forge" links
    changes_self_approval: str = "sole-approver-only"  # sole-approver-only | never: may the asker approve (2026-11-06)
    changes_approvers_team: str = "approvers"      # the forge team whose approval the branch rule wants
    forge_namespace: str = "tockmox-forge"         # service side: where the built-in forge and its copy jobs run
    forge_release: str = "tockmox-forge"           # service side: its release (CronJobs <release>-offsite, -drill-check)
    move_cronjob: str = ""                         # service side: bootstrap-forge's suspended <release>-move
    move_request_secret: str = ""                  # service side: the one Secret a move Job reads its request from
    argocd_namespace: str = "argocd"
    values_files: tuple = tuple(VALUES_FILES.items())  # service side: (which, repo path) for the files a change edits
    activity_configmap: str = "tockmox-actions-activity"
    namespace: str = ""                            # service side: where the activity ConfigMap lives
    step_up_max_age: int = STEP_UP_MAX_AGE
    extra: dict = field(default_factory=dict)

    def values_file(self, which: str) -> str:
        return dict(self.values_files).get(which, "")

    def on(self, kind: str) -> bool:
        k = KINDS.get(kind)
        return bool(k) and k[0] in self.enabled

    @property
    def any(self) -> bool:
        return bool(self.enabled) and bool(self.url or self.namespace)


def parse(raw) -> Config:
    """Validated at start: a malformed block stops the process with the reason, like every other config block."""
    if not raw:
        return Config()
    if not isinstance(raw, dict):
        raise ValueError("actions: must be a mapping")
    on = set()
    for sw in SWITCHES:
        v = raw.get(sw) or {}
        if not isinstance(v, dict):
            raise ValueError(f"actions.{sw}: must be a mapping")
        if v.get("enabled"):
            on.add(sw)
    unknown = set(raw) - set(SWITCHES) - {"url", "activityConfigMap", "namespace", "stepUpMaxAgeSeconds"}
    mv = raw.get("moveForge") or {}
    mv_unknown = set(mv) - {"enabled", "image", "forgeNamespace", "forgeRelease", "cronJob", "requestSecret", "argocdNamespace"}
    if mv_unknown:
        raise ValueError(f"actions.moveForge: unknown key(s) {sorted(mv_unknown)}")
    for k in ("forgeNamespace", "forgeRelease", "cronJob", "requestSecret", "argocdNamespace"):
        if mv.get(k) and not DNS_LABEL.fullmatch(str(mv[k])):
            raise ValueError(f"actions.moveForge.{k} must be a DNS label")
    ch = raw.get("changes") or {}
    ch_unknown = set(ch) - {"enabled", "apiUrl", "repo", "baseBranch", "botTokenFile", "webUrl", "oauth",
                            "forgeNamespace", "forgeRelease", "valuesFiles", "selfApproval", "approversTeam"}
    if ch_unknown:
        raise ValueError(f"actions.changes: unknown key(s) {sorted(ch_unknown)}")
    oa = ch.get("oauth") or {}
    if not isinstance(oa, dict) or set(oa) - {"authorizeUrl", "tokenUrl", "clientId", "clientIdFile", "clientSecretFile"}:
        raise ValueError("actions.changes.oauth: a mapping of authorizeUrl, tokenUrl, clientId or clientIdFile, and "
                         "clientSecretFile")
    for k, v in (("apiUrl", ch.get("apiUrl")), ("webUrl", ch.get("webUrl")), ("oauth.authorizeUrl", oa.get("authorizeUrl")),
                 ("oauth.tokenUrl", oa.get("tokenUrl"))):
        if v and not str(v).startswith(("http://", "https://")):
            raise ValueError(f"actions.changes.{k} must be http:// or https://")
    if ch.get("repo") and not REPO.fullmatch(str(ch["repo"])):
        raise ValueError("actions.changes.repo must be owner/name")
    if ch.get("baseBranch") and not re.fullmatch(r"[A-Za-z0-9._/-]{1,100}", str(ch["baseBranch"])):
        raise ValueError("actions.changes.baseBranch must be a branch name")
    for k in ("forgeNamespace", "forgeRelease"):
        if ch.get(k) and not DNS_LABEL.fullmatch(str(ch[k])):
            raise ValueError(f"actions.changes.{k} must be a DNS label")
    if ch.get("selfApproval") not in (None, "", "sole-approver-only", "never"):
        raise ValueError("actions.changes.selfApproval must be sole-approver-only or never")
    if ch.get("approversTeam") and not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", str(ch["approversTeam"])):
        raise ValueError("actions.changes.approversTeam must be a team name")
    vf = ch.get("valuesFiles") or {}
    if not isinstance(vf, dict) or set(vf) - set(VALUES_FILES):
        raise ValueError(f"actions.changes.valuesFiles: a mapping of {sorted(VALUES_FILES)} to repo paths")
    files = dict(VALUES_FILES)
    for k, v in vf.items():
        if v:
            if not VALUES_PATH.fullmatch(str(v)):
                raise ValueError(f"actions.changes.valuesFiles.{k} must be a .yaml path inside the site repository")
            files[k] = str(v)
    if unknown:
        raise ValueError(f"actions: unknown key(s) {sorted(unknown)}")
    jobs = []
    for i, j in enumerate(((raw.get("runJob") or {}).get("allow") or [])):
        ns, name, part = (str((j or {}).get(k, "")) for k in ("namespace", "name", "part"))
        if not (DNS_LABEL.fullmatch(ns) and DNS_LABEL.fullmatch(name)) or (part and not PART_ID.fullmatch(part)):
            raise ValueError(f"actions.runJob.allow[{i}]: needs a namespace and a CronJob name (DNS labels), and optionally a part id")
        jobs.append((ns, name, part))
    wl = []
    for i, w in enumerate(((raw.get("restart") or {}).get("allow") or [])):
        ns, name, part = (str((w or {}).get(k, "")) for k in ("namespace", "name", "part"))
        kind = str((w or {}).get("kind", "Deployment"))
        if not (DNS_LABEL.fullmatch(ns) and DNS_NAME.fullmatch(name)) or kind not in WORKLOAD_KINDS or \
                (part and not PART_ID.fullmatch(part)):
            raise ValueError(f"actions.restart.allow[{i}]: needs a namespace, a kind (Deployment or StatefulSet) and a name, "
                             "and optionally a part id")
        wl.append((ns, kind, name, part))
    argo = raw.get("argocd") or {}
    ident = raw.get("identity") or {}
    ug = str(ident.get("userGroup", "tockmox-users"))
    if not GROUP_NAME.fullmatch(ug):
        raise ValueError("actions.identity.userGroup must be a group name")
    rg = ident.get("recoveryGroups") or []
    if not isinstance(rg, list) or not all(isinstance(g, str) and GROUP_NAME.fullmatch(g) for g in rg):
        raise ValueError("actions.identity.recoveryGroups must be a list of group names")
    iapi = str(ident.get("apiUrl", "")).rstrip("/")
    if iapi and not iapi.startswith(("http://", "https://")):
        raise ValueError("actions.identity.apiUrl must be http:// or https://")
    url = str(raw.get("url", "")).rstrip("/")
    if url and not url.startswith(("http://", "https://")):
        raise ValueError("actions.url must be http:// or https://")
    age = int(raw.get("stepUpMaxAgeSeconds", STEP_UP_MAX_AGE))
    if not 60 <= age <= 900:
        raise ValueError("actions.stepUpMaxAgeSeconds must be between 60 and 900")
    return Config(url=url, enabled=frozenset(on), jobs=tuple(jobs), workloads=tuple(wl),
                  argocd_url=str(argo.get("url", "")).rstrip("/"), argocd_token_file=str(argo.get("tokenFile", "")),
                  identity_api=iapi, identity_token_file=str(ident.get("tokenFile", "")), user_group=ug,
                  recovery_groups=tuple(rg),
                  changes_api=str(ch.get("apiUrl", "")).rstrip("/"), changes_repo=str(ch.get("repo", "")),
                  changes_base=str(ch.get("baseBranch") or "main"), changes_bot_token_file=str(ch.get("botTokenFile", "")),
                  changes_authorize_url=str(oa.get("authorizeUrl", "")), changes_token_url=str(oa.get("tokenUrl", "")),
                  changes_client_id=str(oa.get("clientId", "")), changes_client_id_file=str(oa.get("clientIdFile", "")),
                  changes_client_secret_file=str(oa.get("clientSecretFile", "")),
                  changes_web=str(ch.get("webUrl", "")).rstrip("/"),
                  changes_self_approval=str(ch.get("selfApproval") or "sole-approver-only"),
                  changes_approvers_team=str(ch.get("approversTeam") or "approvers"),
                  forge_namespace=str(ch.get("forgeNamespace") or "tockmox-forge"),
                  forge_release=str(ch.get("forgeRelease") or mv.get("forgeRelease") or "tockmox-forge"),
                  move_cronjob=str(mv.get("cronJob") or ""), move_request_secret=str(mv.get("requestSecret") or ""),
                  argocd_namespace=str(mv.get("argocdNamespace") or "argocd"),
                  values_files=tuple(sorted(files.items())),
                  activity_configmap=str(raw.get("activityConfigMap", "tockmox-actions-activity")),
                  namespace=str(raw.get("namespace", "")), step_up_max_age=age)


# ---------------------------------------------------------------- the intent

def new_key() -> str:
    return str(uuid.uuid4())


def intent(kind: str, target: dict, params: dict | None, sub: str, key: str | None = None) -> dict:
    return {"v": 1, "kind": kind, "target": dict(target), "params": dict(params or {}), "key": key or new_key(),
            "sub": sub, "at": int(time.time())}


def canonical(it: dict) -> bytes:
    return json.dumps(it, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def nonce_for(it: dict) -> str:
    """The OIDC nonce that binds one sign-in to exactly this intent."""
    return base64.urlsafe_b64encode(hashlib.sha256(b"tockmox-action:" + canonical(it)).digest()).rstrip(b"=").decode()


def step_up(kind: str) -> bool:
    return bool(KINDS.get(kind, (None, None, False))[2])


def check(cfg: Config, it: dict) -> dict:
    """The intent as this side will carry it out, or Refused. Both the UI (before it sends the browser to sign in)
    and the service (before it acts) run it, so a UI that skipped it gains nothing."""
    if not isinstance(it, dict) or it.get("v") != 1:
        raise Refused("not an intent this version understands")
    kind = it.get("kind")
    if kind not in KINDS:
        raise Refused(f"no such action {kind!r}")
    if not cfg.on(kind):
        raise Refused(f"the {KINDS[kind][0]} actions are not turned on here")
    t, p = it.get("target") or {}, it.get("params") or {}
    if not isinstance(t, dict) or not isinstance(p, dict):
        raise Refused("target and params must be objects")
    key = str(it.get("key", ""))
    if not UUID.fullmatch(key):
        raise Refused("the intent has no valid idempotency key")
    if not it.get("sub") or not isinstance(it.get("at"), int):
        raise Refused("the intent names nobody, or no time")
    if kind == "silence":
        alerts = t.get("alerts")
        if not isinstance(alerts, list) or not 1 <= len(alerts) <= 20:
            raise Refused("a silence names between 1 and 20 alerts")
        for a in alerts:
            if not isinstance(a, dict) or not ALERTNAME.fullmatch(str(a.get("alertname", ""))):
                raise Refused("an alert name is not a Prometheus alert name")
            ns = str(a.get("namespace", ""))
            if ns and not DNS_LABEL.fullmatch(ns):
                raise Refused(f"{ns!r} is not a namespace")
            if a["alertname"] in NEVER_SILENCE:
                raise Refused(f"{a['alertname']} proves the alert path works and is never silenced")
        if not PART_ID.fullmatch(str(t.get("part", ""))):
            raise Refused("a silence names the part it is for")
        hours = p.get("hours")
        if not isinstance(hours, int) or not 1 <= hours <= MAX_SILENCE_HOURS:
            raise Refused(f"a silence lasts from 1 to {MAX_SILENCE_HOURS} hours")
        reason = str(p.get("reason", "")).strip()
        if not reason or len(reason) > 300:
            raise Refused("a silence needs a reason (at most 300 characters)")
    elif kind == "expire":
        if not UUID.fullmatch(str(t.get("silence", ""))):
            raise Refused("that is not a silence id")
    elif kind == "run-job":
        if (str(t.get("namespace", "")), str(t.get("name", ""))) not in {j[:2] for j in cfg.jobs}:
            raise Refused("that CronJob is not on the run-now allowlist")
    elif kind in ("refresh", "sync"):
        if not DNS_NAME.fullmatch(str(t.get("app", ""))):
            raise Refused("that is not an Argo CD application name")
    elif kind == "restart":
        if (str(t.get("namespace", "")), str(t.get("kind", "")), str(t.get("name", ""))) not in {w[:3] for w in cfg.workloads}:
            raise Refused("that workload is not on the restart allowlist")
    elif kind == "test-alert":
        if t or p:
            raise Refused("a test alert takes no target")
    elif kind in IDENTITY_KINDS:
        pk, name = t.get("user"), str(t.get("username", ""))
        if not isinstance(pk, int) or isinstance(pk, bool) or pk < 1 or not USERNAME.fullmatch(name) or set(t) - {"user", "username"}:
            raise Refused("an identity action names one user, by id and username")
        if kind == "recovery-link":
            if p.get("hours") not in RECOVERY_HOURS or set(p) - {"hours"}:
                raise Refused("a recovery link lasts 1, 24 or 72 hours")
        elif p:
            raise Refused("a membership change takes no parameters")
    elif kind in CHANGE_KINDS:
        n, title = t.get("number"), t.get("title", "")
        if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= 10_000_000:
            raise Refused("a change is named by its number")
        if not isinstance(title, str) or len(title) > 200 or any(ord(c) < 32 for c in title):
            raise Refused("a change's title is one line of at most 200 characters")
        need = "merge" if kind == "revert-change" else "head"
        if not SHA.fullmatch(str(t.get(need, ""))) or set(t) - {"number", "title", need}:
            raise Refused(f"a change action names the change's number, title and the {need} commit it was shown at")
        if kind == "decline-change":
            r = p.get("reason", "")
            if set(p) - {"reason"} or not isinstance(r, str) or len(r) > 300:
                raise Refused("a decline takes at most a reason of 300 characters")
        elif p:
            raise Refused(f"{kind} takes no parameters")
    elif kind == "open-change":
        title, applied = t.get("title", ""), str(t.get("applied", ""))
        if t.get("what") not in DRAFT_WHATS or not DIGEST.fullmatch(str(t.get("draft", ""))) or \
                set(t) - {"what", "draft", "title", "applied"}:
            raise Refused("opening a change names what it changes and the draft the page made")
        if not isinstance(title, str) or not title.strip() or len(title) > 200 or any(ord(c) < 32 for c in title):
            raise Refused("a change's title is one line of at most 200 characters")
        if applied and not SHA.fullmatch(applied):
            raise Refused("the applied revision is not a commit")
        if p:
            raise Refused("opening a change takes no parameters")
    elif kind == "set-capability":
        cap, en = t.get("capability"), t.get("enabled")
        if cap not in CAPABILITIES or not isinstance(en, bool) or set(t) - {"capability", "enabled"}:
            raise Refused("setting a capability names one of the eight capabilities and on or off")
        if cap in NEVER_OFF_FROM_THE_CONSOLE and not en:
            raise Refused(f"{cap} is how you sign in to this console, so it is not turned off from here: that change "
                          f"would lock out whoever approves it. Set capabilities.{cap}.enabled in site/values/global.yaml "
                          "by hand if you mean it")
        if p:
            raise Refused("setting a capability takes no parameters")
    elif kind == "set-feature":
        f, en = t.get("feature"), t.get("enabled")
        if f not in FEATURES or not isinstance(en, bool) or set(t) - {"feature", "enabled"}:
            raise Refused(f"setting a console feature names one of {sorted(FEATURES)} and on or off")
        if p:
            raise Refused("setting a console feature takes no parameters")
    elif kind == "assign-job":
        job, role = t.get("job"), t.get("role")
        if not (isinstance(job, str) and JOB_NAME.fullmatch(job) and isinstance(role, str) and ROLE_ID.fullmatch(role)) \
                or set(t) - {"job", "role"}:
            raise Refused("giving work to a role names one scheduled job and one role")
        if p:
            raise Refused("giving work to a role takes no parameters")
    elif kind == "bump-release":
        frm, to, bk, pf = t.get("from"), t.get("to"), t.get("kind"), t.get("preflight")
        if not (isinstance(frm, str) and RELEASE_TAG.fullmatch(frm) and isinstance(to, str) and RELEASE_TAG.fullmatch(to)) \
                or frm == to or bk not in BUMP_KINDS or set(t) - {"from", "to", "kind", "preflight"}:
            raise Refused("an upgrade names the release you are on, the one to move to, and the kind of upgrade")
        if not isinstance(pf, list) or not 1 <= len(pf) <= 12:
            raise Refused("an upgrade carries the Upgrade page's preflight")
        for c in pf:
            if not isinstance(c, dict) or set(c) != {"label", "state", "manual"} or not isinstance(c["label"], str) \
                    or not 0 < len(c["label"]) <= 200 or any(ord(x) < 32 for x in c["label"]) \
                    or c["state"] not in PREFLIGHT_STATES or not isinstance(c["manual"], bool):
                raise Refused("a preflight check is a label, a state and whether it is checked by hand")
            if not c["manual"] and c["state"] != "ok":
                raise Refused(f"the preflight is not green ({c['label']}); open the Upgrade page again")
        if p:
            raise Refused("an upgrade takes no parameters")
    elif kind == "move-forge":
        mode, to, after = t.get("mode"), str(t.get("to", "")), str(t.get("after", ""))
        if mode not in MOVE_MODES or set(t) - {"mode", "to", "after"}:
            raise Refused("moving the site names check, move or finish, and the repository")
        if not MOVE_TO.fullmatch(to) or ".." in to:
            raise Refused("the repository is an https URL with no credentials, query or fragment in it")
        if mode == "move":
            if not (MOVE_JOB.fullmatch(after) and after.split("-move-")[1].startswith("check-")):
                raise Refused("the move follows a clean check of the same repository")
        elif after:
            raise Refused(f"a {mode} follows nothing")
        if p:
            raise Refused("moving the site takes no parameters; its credentials travel beside the intent")
    elif kind == "add-admin":
        if not ADMIN_USERNAME.fullmatch(str(t.get("username", ""))) or set(t) - {"username"}:
            raise Refused("adding an administrator names one username, with no spaces")
        if p:
            raise Refused("adding an administrator takes no parameters")
    return it


# ---------------------------------------------------------------- what the confirm panel says

def _until(hours: int, now: float | None = None) -> float:
    return (now or time.time()) + hours * 3600


def describe(it: dict, fmt_time=lambda ts: time.strftime("%H:%M", time.localtime(ts)), choosing: bool = False) -> dict:
    """Target, effect and undo in words, for the confirm panel and the Activity row. choosing: the confirm panel, where
    the admin still picks how long (a silence, a recovery link), so the words name no length (the lab run, 2026-11-01:
    "good for 24 hours" over radio buttons offering 1 hour and 3 days)."""
    k, t, p = it["kind"], it.get("target") or {}, it.get("params") or {}
    if k == "silence":
        names = sorted({a["alertname"] for a in t.get("alerts", [])})
        n = len(t.get("alerts", []))
        label = t.get("label") or t.get("part", "")
        until = fmt_time(_until(int(p.get("hours", 1)), it.get("at")))
        nss = sorted({a.get("namespace", "") for a in t.get("alerts", [])})
        where = ", ".join(f"namespace {x}" for x in nss if x) or "alerts that name no namespace"
        if "" in nss and any(nss):
            where += ", and alerts that name no namespace"
        return {"title": f"Silence {n} alert{'s' if n != 1 else ''} on {label}?",
                "summary": f"Silenced {n} alert{'s' if n != 1 else ''} on {label} for {p.get('hours')}h",
                "target": f"{', '.join(names)} ({where})",
                "effect": f"Alertmanager stops notifying for every alert of {'these names' if len(names) != 1 else 'this name'} "
                          f"in {where} {'for as long as you choose below' if choosing else 'until ' + until}, on this part "
                          f"or another. They stay on Status, marked silenced.",
                "undo": "Expire the silence, on Status or in Activity."}
    if k == "expire":
        return {"title": "Expire this silence?", "summary": "Expired a silence", "target": t.get("label") or t.get("silence", ""),
                "effect": "Alertmanager notifies for these alerts again from now.",
                "undo": "Silence them again from Status."}
    if k == "run-job":
        name = f"{t.get('namespace')}/{t.get('name')}"
        return {"title": f"Run {t.get('name')} now?", "summary": f"Ran {t.get('name')} now", "target": name,
                "effect": f"Starts one Job from the CronJob {name}, as its schedule would. Its schedule is unchanged.",
                "undo": "Nothing to undo: a run is harmless to repeat. A run that should not finish can be deleted with kubectl."}
    if k == "refresh":
        return {"title": f"Refresh {t.get('app')}?", "summary": f"Refreshed {t.get('app')}", "target": t.get("app"),
                "effect": "Argo CD compares the application with Git again now instead of at its next poll. Nothing is applied.",
                "undo": "Nothing to undo."}
    if k == "sync":
        return {"title": f"Sync {t.get('app')}?", "summary": f"Synced {t.get('app')}", "target": t.get("app"),
                "effect": "Argo CD applies what Git says for this application now, without pruning. Its source is not changed.",
                "undo": "Git is the record: to go back, revert the commit and sync again."}
    if k == "restart":
        name = f"{t.get('namespace')}/{t.get('name')}"
        return {"title": f"Restart {t.get('name')}?", "summary": f"Restarted {t.get('name')}", "target": f"{t.get('kind')} {name}",
                "effect": "Replaces its pods one at a time, as kubectl rollout restart does. Nothing else about it changes.",
                "undo": "Nothing to undo: the new pods run the same configuration."}
    if k == "recovery-link":
        u, h = t.get("username", ""), int(p.get("hours", 24))
        span = "as long as you choose below" if choosing else {1: "one hour", 24: "24 hours", 72: "three days"}.get(h, f"{h} hours")
        return {"title": f"Make a recovery link for {u}?", "summary": f"Made a recovery link for {u}", "target": u,
                "effect": f"Authentik makes a link, good once and for {span}, that lets {u} set a new password. It is "
                          f"shown to you once, on the next page, for you to send them. Whoever holds it can take over "
                          f"the account until it is used or expires, so send it the way you would send a password.",
                "undo": f"Making another link for {u} replaces this one. To cancel it without a new one, delete the "
                        f"token in Authentik's admin console (Directory, Tokens and App passwords)."}
    if k == "add-member":
        u = t.get("username", "")
        return {"title": f"Add {u} to the user group?", "summary": f"Added {u} to the user group", "target": u,
                "effect": f"{u} joins the user group, so the consoles open to users let them in on their next sign-in "
                          "(Authentik can take up to five minutes to notice: it caches its access decisions). "
                          "Administrators are not changed by this: that group is set in Git.",
                "undo": f"Remove {u} from the user group, here."}
    if k == "remove-member":
        u = t.get("username", "")
        return {"title": f"Remove {u} from the user group?", "summary": f"Removed {u} from the user group", "target": u,
                "effect": f"{u} leaves the user group, so the consoles open to users stop letting them in at their next "
                          "sign-in, within five minutes (Authentik caches its access decisions that long). A session "
                          "already open in a console lasts until it ends. They can still sign in to Authentik itself; "
                          "to stop that, deactivate the account in Authentik's admin console.",
                "undo": f"Add {u} to the user group again, here."}
    if k in CHANGE_KINDS:
        n, title = t.get("number"), t.get("title") or f"change #{t.get('number')}"
        if k == "approve-change":
            return {"title": f"Approve and apply #{n}?", "summary": f"Approved and applied #{n}: {title}",
                    "target": f"#{n} {title}, at commit {str(t.get('head', ''))[:7]}",
                    "effect": "Your approval is recorded in the site's forge as you, and the change merges with an "
                              "Approved-by line naming you in the history. Argo CD applies it within minutes. Only the "
                              "commit you were shown is approved: if the change moved since, nothing is done.",
                    "undo": "Revert it from Platform > Changes: that opens the opposite change, which waits for an approval."}
        if k == "decline-change":
            return {"title": f"Decline #{n}?", "summary": f"Declined #{n}: {title}", "target": f"#{n} {title}",
                    "effect": "The change is closed in the site's forge as you, with your reason. Nothing is applied.",
                    "undo": "Reopen it in the forge, or ask for it again."}
        return {"title": f"Revert #{n}?", "summary": f"Opened a revert of #{n}: {title}",
                "target": f"#{n} {title}, applied as commit {str(t.get('merge', ''))[:7]}",
                "effect": "Opens the opposite change: every file it changed goes back to what it was before. The "
                          "revert waits on Platform > Changes for an approval, like any change; nothing is applied yet.",
                "undo": "Decline the revert."}
    if k == "open-change":
        title = t.get("title") or "a change"
        return {"title": "Open this as a change?", "summary": f"Opened a change: {title}", "target": title,
                "effect": "Opens a change in the site's forge with exactly the edit shown, as the change bot. Nothing "
                          "is applied: it waits on Platform > Changes for an administrator's approval, like any change.",
                "undo": "Decline it on Platform > Changes."}
    if k == "add-admin":
        u = t.get("username", "")
        return {"title": f"Make {u} an administrator?", "summary": f"Opened a change making {u} an administrator",
                "target": u,
                "effect": f"Opens a change adding {u} to sso.adminUsers in the site's identity values. Nothing changes "
                          f"until an administrator approves it; then Argo CD's next sync adds {u} to the admin group "
                          f"(a name Authentik does not know yet is skipped and logged).",
                "undo": f"Decline the change. Once applied, taking it out of sso.adminUsers does not remove {u} from "
                        "the admin group (the job only adds): remove them in Authentik's admin console as well."}
    if k == "set-capability":
        from .capabilities import CATALOG
        cap, en = t.get("capability", ""), bool(t.get("enabled"))
        c = next((x for x in CATALOG if x.key == cap), None)
        name, comps = (c.name, c.components) if c else (cap, "its components")
        word = "on" if en else "off"
        return {"title": f"Turn {name} {word}?", "summary": f"Opened a change turning {name} {word}",
                "target": f"capabilities.{cap}.enabled: {str(en).lower()} in the site values every layer reads",
                "effect": f"Opens a change setting only capabilities.{cap}.enabled to {str(en).lower()} in "
                          f"site/values/global.yaml, as the change bot. Nothing changes until an administrator "
                          f"approves it; then Argo CD {'adds' if en else 'removes'} what {name} owns, across every "
                          f"layer: {comps}.",
                "undo": f"Decline the change. Once applied, turn {name} {'off' if en else 'on'} again from Platform > "
                        "Capabilities, which opens the opposite change."}
    if k == "set-feature":
        f, en = t.get("feature", ""), bool(t.get("enabled"))
        name = FEATURES.get(f, (f,))[0]
        word = "on" if en else "off"
        key = ".".join(FEATURES[f][1]) if f in FEATURES else f
        return {"title": f"Turn {name} {word}?", "summary": f"Opened a change turning {name} {word}",
                "target": f"{key}: {str(en).lower()} in the AI layer's site values",
                "effect": f"Opens a change setting only {key} to {str(en).lower()} in site/values/ai.yaml, as the change "
                          "bot. Nothing changes until an administrator approves it; then Argo CD restarts the console "
                          + ("with the Platform area (Overview, Organization, Schedule, and Cases and Specialists where "
                             "they are connected) for administrators." if en else
                             "without the Platform area: its pages answer 404 and leave the menu."),
                "undo": f"Decline the change. Once applied, turn {name} {'off' if en else 'on'} again from Platform > "
                        "Capabilities, which opens the opposite change."}
    if k == "assign-job":
        job, role = t.get("job", ""), t.get("role", "")
        key = ".".join(ASSIGN_PATH)
        return {"title": f"Give {job} to {role}?", "summary": f"Opened a change giving {job} to {role}",
                "target": f"{key}.{job}: {role} in the AI layer's site values",
                "effect": f"Opens a change setting only {key}.{job} to {role} in site/values/ai.yaml, as the change bot. "
                          f"Nothing changes until an administrator approves it; then the console restarts and lists "
                          f"{job} under {role}, whose numbers and schedule now count it. A tockmox.com/practice label on "
                          "the workload still wins over this.",
                "undo": f"Decline the change. Once applied, delete the {job} line under {key} in site/values/ai.yaml, "
                        "and the job reads as having no owner again."}
    if k == "bump-release":
        frm, to, bk = t.get("from", ""), t.get("to", ""), t.get("kind", "")
        hand = [c["label"] for c in t.get("preflight") or [] if c.get("manual")]
        return {"title": f"Upgrade Tockmox from {frm} to {to}?", "summary": f"Opened a change upgrading Tockmox to {to}",
                "target": f"every layer's Application, {frm} to {to} ({bk} upgrade)",
                "effect": f"Opens a change, as the change bot, that moves every layer's targetRevision from {frm} to {to} "
                          f"in {APPLICATIONS_FOLDER}, and nothing else; the preflight goes in its description. Nothing "
                          "changes until an administrator approves it; then Argo CD moves each layer, wave by wave, and the guide's steps "
                          "6 and 7 confirm it landed."
                          + (f" Before approving, do what the console cannot check: {'; '.join(hand)}." if hand else ""),
                "undo": "Decline the change. Once applied, follow Roll back in docs/deployment/upgrade.md: swapping the "
                        "revisions puts every manifest back, and a release that migrated a database needs the backup "
                        "from the guide's step 2 first."}
    if k == "move-forge":
        to, mode = t.get("to", ""), t.get("mode", "")
        if mode == "check":
            return {"title": "Check the target repository?", "summary": f"Checked {to} for a move", "target": to,
                    "effect": "Runs the move's first step only: the repository must be empty and the credential must "
                              "read it. It says what would move (branches, tags, main) and how many files the change "
                              "would rewrite. Nothing is pushed and nothing changes here.",
                    "undo": "Nothing to undo."}
        if mode == "move":
            return {"title": f"Move the site to {to}?", "summary": f"Started moving the site to {to}", "target": to,
                    "effect": "The whole history (every branch and tag) is pushed to the target, Argo CD gets a read "
                              "credential for it, and one change repoints the site at it. That change waits on "
                              "Platform > Changes for an approver other than you, like every change; nothing moves "
                              "until it merges. Then Finish the move archives the built-in repository (nothing is deleted).",
                    "undo": "Before the change merges: decline it; the target keeps a copy you can delete. After: the "
                            "built-in repository is archived, not deleted; revert the change to go back."}
        return {"title": f"Finish the move to {to}?", "summary": f"Finished moving the site to {to}", "target": to,
                "effect": "Pushes main to the target again (it now holds the merged change), re-applies the root "
                          "Application from the target, and archives the built-in repository: read-only, nothing deleted. "
                          "From then on Argo CD reads only the target.",
                "undo": "Unarchive the built-in repository in the forge and revert the move's change; Argo CD reads "
                        "the built-in forge again once the root is re-applied from it."}
    if k == "test-alert":
        return {"title": "Send a test alert to your phone?", "summary": "Sent a test alert",
                "target": "the alert path: Alertmanager, the alert bridge, your phone",
                "effect": "One warning, TockmoxTestAlert, goes down the same path as every other alert. It resolves by itself after five minutes.",
                "undo": "Nothing to undo."}
    return {"title": k, "summary": k, "target": "", "effect": "", "undo": ""}


def silence_matchers(t: dict) -> list[list[dict]]:
    """One silence per namespace, each naming exactly its alerts. An alert with no namespace label is matched with
    namespace="" (absent), never every namespace."""
    by_ns: dict[str, set] = {}
    for a in t.get("alerts", []):
        by_ns.setdefault(str(a.get("namespace", "")), set()).add(a["alertname"])
    out = []
    for ns in sorted(by_ns):
        names = sorted(by_ns[ns])
        m = [{"name": "alertname", "value": names[0], "isRegex": False, "isEqual": True}] if len(names) == 1 else \
            [{"name": "alertname", "value": "|".join(re.escape(n) for n in names), "isRegex": True, "isEqual": True}]
        m.append({"name": "namespace", "value": ns, "isRegex": False, "isEqual": True})
        out.append(m)
    return out

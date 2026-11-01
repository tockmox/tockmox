# SPDX-License-Identifier: Apache-2.0
"""Actions from the console (TM-1311, TM-1313; specs/tockmox-ui/SPEC.md section 7 in the planning repo).

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
              narrow Authentik service account (TM-1315); every one asks for a fresh sign-in
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
}
SWITCHES = ("silence", "runJob", "argocd", "restart", "testAlert", "identity")
IDENTITY_KINDS = ("recovery-link", "add-member", "remove-member")
RECOVERY_HOURS = (1, 24, 72)
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
    back to a caller. Text read from an upstream response never goes in it; that goes to the log (TM-1356)."""

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
    activity_configmap: str = "tockmox-actions-activity"
    namespace: str = ""                            # service side: where the activity ConfigMap lives
    step_up_max_age: int = STEP_UP_MAX_AGE
    extra: dict = field(default_factory=dict)

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
                "effect": "Replaces its pods one at a time, as `kubectl rollout restart` does. Nothing else about it changes.",
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
                "effect": f"{u} joins the user group, so the consoles open to users let them in on their next sign-in. "
                          "Administrators are not changed by this: that group is set in Git.",
                "undo": f"Remove {u} from the user group, here."}
    if k == "remove-member":
        u = t.get("username", "")
        return {"title": f"Remove {u} from the user group?", "summary": f"Removed {u} from the user group", "target": u,
                "effect": f"{u} leaves the user group, so the consoles open to users stop letting them in at their next "
                          "sign-in. A session already open in a console lasts until it ends. Their account stays.",
                "undo": f"Add {u} to the user group again, here."}
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

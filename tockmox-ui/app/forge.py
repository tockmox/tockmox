# SPDX-License-Identifier: Apache-2.0
"""The site forge, as tockmox-actions sees it: the changes waiting on Platform > Changes, and the three things a
person can do to one (specs/site-forge/SPEC.md "Changing your site" in the planning repo).

Two identities, never a third:

  the change bot   a token scoped to the site repository (write:repository, write:issue), made by bootstrap-forge.
                   It reads the open changes and their diffs, and opens a revert. It cannot approve: the branch rule
                   wants an approval from the approvers team, and the bot is not in it.
  the person       for approve and decline only: a token the forge mints for THAT person when the browser comes back
                   from the forge's own sign-in (which is Authentik's), exchanged here with the console's OAuth2
                   client secret, used for one review and one merge, and never stored.

No forge admin token is held here or anywhere in the console (measured on Forgejo 15.0.11: nothing stops the
admin from merging past the branch rule, so a service holding that token would approve everything).

The merge is a merge commit, not a squash: Do=merge keeps the Approved-by line in the history (measured on 15.0.11;
Do=squash drops it), so who approved travels with every off-site copy.
"""
from __future__ import annotations

import base64
import hashlib
import logging
import os
import re

import httpx

from . import actions as act
from . import values_edit as ve

log = logging.getLogger("tockmox.actions.forge")
DIFF_MAX = 400_000                  # a diff larger than this is shown cut, with the forge's link for the rest
LIST_MAX = 50
REVERT_FILES_MAX = 200
ORIGIN = re.compile(r"^Tockmox-Origin:\s*([a-z0-9-]{1,40})\s*$", re.M | re.I)
# Who asked for a change, as their identity provider username (the forge registers people under the same name). The
# console writes it on every change it opens, so the person stays visible behind the change bot (separation of duties,
# Jeff's ruling 2026-11-06: the person who asked does not approve, unless they are the only approver).
REQUESTED = re.compile(r"^Tockmox-Requested-By:\s*([A-Za-z0-9_.@-]{1,100})\s*$", re.M)
TRAILER = re.compile(r"^Tockmox-[A-Za-z-]+:\s")
SELF_APPROVAL = ("sole-approver-only", "never")


class Paused(Exception):
    """The forge did not answer. The page says "Changes paused"; nothing is done."""


def summary_of(body: str) -> str:
    """The change's plain-language summary: its description's first paragraph, without markup or trailers."""
    para = []
    for ln in str(body or "").replace("\r", "").split("\n"):
        s = ln.strip()
        if not s:
            if para:
                break
            continue
        if s.startswith(("#", "<!--", "```")) or TRAILER.match(s):
            continue
        para.append(s)
    out = " ".join(para)
    return out[:400] + ("..." if len(out) > 400 else "")


def requester_of(pr: dict) -> str:
    """The username the console recorded as having asked for the change, or "" (a bot's change, or one opened by hand)."""
    m = REQUESTED.search(str(pr.get("body") or ""))
    return m.group(1) if m else ""


def trailers(requested: str) -> str:
    return (f"Tockmox-Requested-By: {requested}\n" if requested else "") + "Tockmox-Origin: console"


def origin_of(pr: dict, bot: str) -> str:
    """Who opened it, in words: the console, the model watcher, another bot, or a person's name."""
    m = ORIGIN.search(str(pr.get("body") or ""))
    if m:
        return {"console": "the console", "model-watcher": "the model watcher"}.get(m.group(1).lower(), m.group(1))
    u = pr.get("user") or {}
    login = str(u.get("login", ""))
    if bot and login == bot:
        return "the console"
    return str(u.get("full_name") or login or "someone")


class Forge:
    def __init__(self, cfg: act.Config, timeout: float = 8.0, transport=None):
        self.cfg, self.timeout, self.transport = cfg, timeout, transport
        self.repo, self.base = cfg.changes_repo, cfg.changes_base
        self._bot_login = ""

    # ------------------------------------------------------------ plumbing

    NOT_CONFIGURED = "no site forge is configured for changes (actions.changes)"

    def unready(self) -> str:
        c = self.cfg
        if not (c.changes_api and c.changes_repo and c.changes_bot_token_file):
            return self.NOT_CONFIGURED
        if not os.path.exists(c.changes_bot_token_file):
            return "the change bot's token is not mounted"
        return "" if self._read(c.changes_bot_token_file) else "the change bot's token is empty"

    @staticmethod
    def _read(path: str) -> str:
        try:
            with open(path, encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def _c(self, token: str):
        return httpx.Client(base_url=self.cfg.changes_api, timeout=self.timeout, transport=self.transport,
                            follow_redirects=False,
                            headers={"Authorization": "token " + token, "Accept": "application/json"})

    def _bot(self):
        why = self.unready()
        if why:
            raise act.Refused(why)
        return self._c(self._read(self.cfg.changes_bot_token_file))

    def _get(self, c, path, **params):
        """GET, or Paused when the forge does not answer (a transport error, a 5xx)."""
        try:
            r = c.get(path, params=params or None)
        except httpx.HTTPError as e:
            raise Paused(type(e).__name__) from e
        if r.status_code >= 500:
            raise Paused(f"HTTP {r.status_code}")
        return r

    @staticmethod
    def _refuse(r, what):
        msg = ""
        try:
            msg = str((r.json() or {}).get("message", ""))[:200]
        except Exception:  # noqa: BLE001
            pass
        if msg:                                       # the forge's words are for the operator's log, not the browser
            log.warning("the forge refused %s (%s): %s", what, r.status_code, msg)
        return act.Refused(f"the forge refused {what} ({r.status_code})")

    def bot_login(self, c) -> str:
        if not self._bot_login:
            r = self._get(c, "/user")
            if r.status_code < 300:
                self._bot_login = str((r.json() or {}).get("login", ""))
        return self._bot_login

    # ------------------------------------------------------------ reading

    def _row(self, c, pr: dict, bot: str) -> dict:
        head = str((pr.get("head") or {}).get("sha", ""))
        checks, state = [], ""
        if head:
            r = self._get(c, f"/repos/{self.repo}/commits/{head}/status")
            if r.status_code < 300:
                j = r.json() or {}
                state = str(j.get("state", ""))
                checks = [{"context": str(x.get("context", "")), "state": str(x.get("status") or x.get("state") or ""),
                           "description": str(x.get("description", ""))[:200]} for x in j.get("statuses") or []]
        return {"number": int(pr.get("number", 0)), "title": str(pr.get("title", ""))[:200],
                "summary": summary_of(pr.get("body", "")), "by": origin_of(pr, bot),
                "author": str((pr.get("user") or {}).get("login", "")),
                "created": str(pr.get("created_at", "")), "updated": str(pr.get("updated_at", "")),
                "head": head, "base": str((pr.get("base") or {}).get("ref", "")),
                "mergeable": pr.get("mergeable"), "checks": checks, "checks_state": state,
                "merged": bool(pr.get("merged")), "merge": str(pr.get("merge_commit_sha") or ""),
                "merged_at": str(pr.get("merged_at") or ""),
                "merged_by": str((pr.get("merged_by") or {}).get("full_name") or (pr.get("merged_by") or {}).get("login") or ""),
                "requested_by": requester_of(pr),
                "self_approved": bool(pr.get("merged") and requester_of(pr) and requester_of(pr).lower()
                                      == str((pr.get("merged_by") or {}).get("login") or "").lower()),
                "url": (f"{self.cfg.changes_web}/{self.repo}/pulls/{pr.get('number')}" if self.cfg.changes_web else "")}

    def changes(self) -> dict:
        """{"open": [...], "applied": [...]}, or Paused. Open: waiting for a decision, newest first. Applied: the last
        merged, newest first, for Revert."""
        with self._bot() as c:
            bot = self.bot_login(c)
            r = self._get(c, f"/repos/{self.repo}/pulls", state="open", sort="newest", limit=LIST_MAX)
            if r.status_code >= 300:
                raise self._refuse(r, "the list of changes")
            opened = [self._row(c, pr, bot) for pr in (r.json() or []) if (pr.get("base") or {}).get("ref") == self.base]
            r = self._get(c, f"/repos/{self.repo}/pulls", state="closed", sort="recentupdate", limit=20)
            applied = []
            if r.status_code < 300:
                for pr in r.json() or []:
                    if pr.get("merged") and (pr.get("base") or {}).get("ref") == self.base:
                        applied.append(self._row(c, pr, bot))
            applied.sort(key=lambda x: x["merged_at"], reverse=True)
        return {"open": opened, "applied": applied[:10]}

    def main_state(self) -> dict:
        """The base branch's head: its commit, when it was made, and its first line. Paused when the forge is down."""
        with self._bot() as c:
            r = self._get(c, f"/repos/{self.repo}/branches/{self.base}")
            if r.status_code >= 300:
                raise self._refuse(r, f"the branch {self.base}")
            cm = (r.json() or {}).get("commit") or {}
        return {"sha": str(cm.get("id", "")), "time": str(cm.get("timestamp", "")),
                "message": str(cm.get("message", "")).split("\n", 1)[0][:200]}

    # ------------------------------------------------------------ a copy to carry (Site history's Download a copy)

    def _clone_url(self) -> str:
        return self.cfg.changes_api.removesuffix("/api/v1") + f"/{self.repo}.git"

    def bundle(self, workdir: str) -> dict:
        """main as one git bundle, made the way the off-site copy job makes it (install/forge-offsite-copy.sh): a bare
        single-branch clone as the bot, a bundle of HEAD and main, verified from an empty repository, and its SHA-256
        in the line `--restore-from file:` checks ("<sum>  site.bundle"). The bot's credential reaches git through
        GIT_CONFIG_* in the environment of that one command, never its arguments. Only the newest bundle is kept."""
        import hashlib
        import shutil
        import subprocess
        import tempfile
        git = shutil.which("git")
        if not git:
            raise act.Refused("this image has no git, so it cannot make a copy")
        why = self.unready()
        if why:
            raise act.Refused(why)
        token = self._read(self.cfg.changes_bot_token_file)
        with self._bot() as c:
            login = self.bot_login(c)
        hdr = "Authorization: Basic " + base64.b64encode(f"{login}:{token}".encode()).decode()
        os.makedirs(workdir, exist_ok=True)
        tmp = tempfile.mkdtemp(dir=workdir)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp, "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader",
               "GIT_CONFIG_VALUE_0": hdr}

        def run(*a):
            r = subprocess.run([git, *a], env=env, capture_output=True, text=True, timeout=300)
            if r.returncode:
                log.warning("git %s failed: %s", a[0], r.stderr[-300:].replace(token, "<token>"))
                raise act.Refused(f"git {a[0]} failed; the forge's log or this pod's says why")
            return r.stdout.strip()
        try:
            repo, out = f"{tmp}/repo.git", f"{tmp}/site.bundle"
            run("clone", "--quiet", "--bare", "--single-branch", "--branch", self.base, self._clone_url(), repo)
            sha = run("-C", repo, "rev-parse", f"refs/heads/{self.base}")
            run("-C", repo, "bundle", "create", out, "HEAD", f"refs/heads/{self.base}")
            run("init", "--bare", "--quiet", f"{tmp}/empty.git")
            run("-C", f"{tmp}/empty.git", "bundle", "verify", out)
            h = hashlib.sha256()
            with open(out, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            digest, size = h.hexdigest(), os.path.getsize(out)
            final = os.path.join(workdir, digest + ".bundle")
            os.replace(out, final)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        for f in os.listdir(workdir):                   # only the newest is kept: the volume is small
            if f.endswith(".bundle") and f != digest + ".bundle":
                try:
                    os.remove(os.path.join(workdir, f))
                except OSError:
                    pass
        return {"sha256": digest, "commit": sha, "bytes": size}

    def diff(self, number: int) -> tuple[str, bool]:
        """The change's diff as text, and whether it was cut at DIFF_MAX."""
        with self._bot() as c:
            r = self._get(c, f"/repos/{self.repo}/pulls/{int(number)}.diff")
            if r.status_code == 404:
                raise act.Refused("the forge has no such change")
            if r.status_code >= 300:
                raise self._refuse(r, "the diff")
            text = r.text
        return text[:DIFF_MAX], len(text) > DIFF_MAX

    def _pull(self, c, number: int) -> dict:
        r = self._get(c, f"/repos/{self.repo}/pulls/{int(number)}")
        if r.status_code == 404:
            raise act.Refused("the forge has no such change")
        if r.status_code >= 300:
            raise self._refuse(r, "the change")
        return r.json() or {}

    # ------------------------------------------------------------ the person

    def sign_in(self) -> dict:
        """What the UI needs to send a browser to the forge's own sign-in: the authorize URL and the console's client
        id (public; the forge makes it up when bootstrap-forge registers the console). {} when not configured."""
        c = self.cfg
        cid = c.changes_client_id or (self._read(c.changes_client_id_file) if c.changes_client_id_file else "")
        if not (c.changes_authorize_url and cid and c.changes_token_url and c.changes_client_secret_file):
            return {}
        return {"authorize_url": c.changes_authorize_url, "client_id": cid}

    def person_token(self, code: str, verifier: str, redirect_uri: str) -> str:
        """The forge's OAuth2 code, exchanged with the console's client secret (which only this pod holds) and the
        PKCE verifier the browser's leg started with, for that person's access token."""
        c = self.cfg
        cid = self.sign_in().get("client_id", "")
        if not cid:
            raise act.Refused("the console has no OAuth2 application in the forge (actions.changes.oauth)")
        secret = self._read(c.changes_client_secret_file)
        if not secret:
            raise act.Refused("the console's OAuth2 client secret is not mounted")
        if not (code and verifier and redirect_uri) or len(code) > 512 or len(verifier) > 256:
            raise act.Refused("the forge's sign-in did not come back with a code")
        try:
            with httpx.Client(timeout=self.timeout, transport=self.transport, follow_redirects=False) as h:
                r = h.post(c.changes_token_url, data={
                    "grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri,
                    "client_id": cid, "client_secret": secret, "code_verifier": verifier},
                    headers={"Accept": "application/json"})
        except httpx.HTTPError as e:
            raise act.Refused("the forge did not answer the sign-in; nothing was done") from e
        if r.status_code >= 300:
            raise self._refuse(r, "the sign-in's code")
        tok = str((r.json() or {}).get("access_token", ""))
        if not tok:
            raise act.Refused("the forge gave no token for the sign-in")
        return tok

    def whoami(self, token: str) -> dict:
        with self._c(token) as c:
            r = self._get(c, "/user")
            if r.status_code >= 300:
                raise self._refuse(r, "the signed-in person")
            u = r.json() or {}
        return {"login": str(u.get("login", "")), "name": str(u.get("full_name") or u.get("login") or ""),
                "email": str(u.get("email", ""))}

    def _fresh(self, c, number: int, head: str) -> dict:
        pr = self._pull(c, number)
        if pr.get("state") != "open" or pr.get("merged"):
            raise act.Refused(f"#{number} is no longer open")
        if (pr.get("base") or {}).get("ref") != self.base:
            raise act.Refused(f"#{number} is not a change to {self.base}")
        now = str((pr.get("head") or {}).get("sha", ""))
        if now != head:
            raise act.Refused(f"#{number} changed since you opened it (now at {now[:7]}); look at it again")
        return pr

    def approve(self, number: int, head: str, token: str, person: dict) -> dict:
        """One review (APPROVED, of exactly `head`) and one merge commit carrying Approved-by, both as the person.
        The forge's branch rule decides: a person outside the approvers team is refused there, whatever this says."""
        line = f"Approved-by: {person['name']} <{person['email']}>" if person.get("email") else f"Approved-by: {person['name']}"
        with self._c(token) as c:
            pr = self._fresh(c, number, head)
            asked = requester_of(pr)
            alone = self._self_approval(c, number, asked, person)
            if asked:
                line = f"Requested-by: {asked}\n{line}"
            if alone:
                line += "\nSelf-approved: sole approver"
            try:
                r = c.post(f"/repos/{self.repo}/pulls/{number}/reviews",
                           json={"event": "APPROVED", "commit_id": head,
                                 "body": "Approved in the Tockmox console." + (" Self-approved: the only approver."
                                                                               if alone else "")})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer; nothing was approved") from e
            if r.status_code >= 300:
                raise self._refuse(r, "the approval")
            title = str(pr.get("title", ""))[:200]
            msg = (f"{summary_of(pr.get('body', ''))}\n\n" if summary_of(pr.get("body", "")) else "") + line + "\n"
            try:
                r = c.post(f"/repos/{self.repo}/pulls/{number}/merge",
                           json={"Do": "merge", "MergeTitleField": f"{title} (#{number})", "MergeMessageField": msg,
                                 "head_commit_id": head})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer the merge; the approval stands, and the change is not "
                                  "applied yet: approve it again") from e
            if r.status_code == 405:
                raise self._refuse(r, "the merge: its branch rule is not met (your approval must count: are you in "
                                      "the approvers team?)")
            if r.status_code >= 300:
                raise self._refuse(r, "the merge")
            merged = self._pull(c, number)
        return {"ref": [f"#{number}", str(merged.get("merge_commit_sha") or "")[:12]],
                "detail": f"merged as {str(merged.get('merge_commit_sha') or '')[:7]}; " + "; ".join(line.split("\n"))}

    def _self_approval(self, c, number: int, asked: str, person: dict) -> bool:
        """Separation of duties (Jeff's ruling 2026-11-06). The person who asked for a change does not approve it, so
        this refuses before anything is posted; the one exception is a site whose approvers team has nobody else in
        it, where refusing would leave the change with no one to approve it (selfApproval: sole-approver-only, the
        default; never refuses that too). Answers True when the exception applies, so the merge says so.
        Fail closed: a team this cannot read is not a team with one member."""
        if not asked or asked.lower() != str(person.get("login", "")).lower():
            return False
        team = self.cfg.changes_approvers_team
        if self.cfg.changes_self_approval == "never":
            raise act.Refused(f"you asked for #{number}, so someone else in the {team} team must approve it "
                              "(selfApproval: never)")
        others = sorted(m for m in self._team(c, team) if m.lower() != asked.lower())
        if others:
            raise act.Refused(f"you asked for #{number}, so someone else in the {team} team must approve it: "
                              + ", ".join(others[:5]) + (" and others" if len(others) > 5 else ""))
        return True

    def _team(self, c, team: str) -> list[str]:
        """The logins in the site organization's team, read with the person's own token. Refused when unreadable."""
        org = self.repo.split("/", 1)[0]
        why = (f"could not read who is in the {team} team, so a change you asked for cannot be approved by you; "
               "ask another approver, or approve it in the forge")
        try:
            r = self._get(c, f"/orgs/{org}/teams/search", q=team)
            hit = next((t for t in ((r.json() or {}).get("data") or []) if str(t.get("name", "")) == team), None) \
                if r.status_code < 300 else None
            if not hit:
                raise act.Refused(why)
            r = self._get(c, f"/teams/{hit.get('id')}/members", limit=LIST_MAX)
        except httpx.HTTPError as e:
            raise act.Refused(why) from e
        if r.status_code >= 300 or not isinstance(r.json(), list):
            raise act.Refused(why)
        return [str(u.get("login", "")) for u in r.json() if u.get("login")]

    def decline(self, number: int, head: str, token: str, person: dict, reason: str) -> dict:
        with self._c(token) as c:
            self._fresh(c, number, head)
            words = f"Declined in the Tockmox console by {person['name']}" + (f": {reason}" if reason else ".")
            try:
                r = c.post(f"/repos/{self.repo}/issues/{number}/comments", json={"body": words})
                if r.status_code >= 300:
                    raise self._refuse(r, "the decline's comment")
                r = c.patch(f"/repos/{self.repo}/pulls/{number}", json={"state": "closed"})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer; the change may still be open") from e
            if r.status_code >= 300:
                raise self._refuse(r, "closing the change")
        return {"ref": [f"#{number}"], "detail": "closed, not applied"}

    # ------------------------------------------------------------ revert, as the bot

    def revert(self, number: int, merge: str, by: str, requested: str = "") -> dict:
        """The opposite change: every file the merge changed, back to its first parent's content, as one commit on a
        new branch, opened as a change. Refused when a file changed again since (that revert is a person's call) or
        when the merge renamed a file."""
        with self._bot() as c:
            pr = self._pull(c, number)
            if not pr.get("merged") or str(pr.get("merge_commit_sha") or "") != merge:
                raise act.Refused(f"#{number} was not applied as {merge[:7]}")
            r = self._get(c, f"/repos/{self.repo}/git/commits/{merge}")
            if r.status_code >= 300:
                raise self._refuse(r, "the applied commit")
            cm = r.json() or {}
            parents = [str(p.get("sha", "")) for p in cm.get("parents") or []]
            if not parents:
                raise act.Refused("the applied commit has no parent to go back to")
            parent = parents[0]
            files = cm.get("files") or []
            if not files or len(files) > REVERT_FILES_MAX:
                raise act.Refused(f"the applied commit names {len(files)} files; revert it by hand")
            ops = []
            for f in files:
                path, status = str(f.get("filename", "")), str(f.get("status", ""))
                if status not in ("added", "modified", "removed", "deleted"):
                    raise act.Refused(f"{path} was {status or 'changed in a way'} the revert cannot undo; revert it by hand")
                at_merge = self._blob(c, path, merge)
                at_base = self._blob(c, path, self.base)
                if at_base != at_merge:
                    raise act.Refused(f"{path} changed again after #{number}; reverting it would undo that too, so "
                                      "revert it by hand")
                if status == "added":
                    ops.append({"operation": "delete", "path": path, "sha": at_base})
                    continue
                content = self._content(c, path, parent)
                if status in ("removed", "deleted"):
                    ops.append({"operation": "create", "path": path, "content": content})
                else:
                    ops.append({"operation": "update", "path": path, "content": content, "sha": at_base})
            branch = f"tockmox/revert-{number}-{merge[:7]}"
            title = f"Revert: {str(pr.get('title', ''))[:180]}"
            msg = f"{title}\n\nReverts #{number} (applied as {merge[:12]}), asked for by {by}.\n\n{trailers(requested)}\n"
            try:
                r = c.post(f"/repos/{self.repo}/contents", json={"branch": self.base, "new_branch": branch,
                                                                  "message": msg, "files": ops})
                if r.status_code == 422 and "exist" in r.text.lower():
                    raise act.Refused(f"a revert of #{number} is already open (branch {branch})")
                if r.status_code >= 300:
                    raise self._refuse(r, "the revert's commit")
                r = c.post(f"/repos/{self.repo}/pulls", json={
                    "base": self.base, "head": branch, "title": title,
                    "body": f"Puts back every file #{number} changed, as it was before it was applied. Asked for in the "
                            f"Tockmox console by {by}.\n\n{trailers(requested)}"})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer; the revert may be half made (look for its branch)") from e
            if r.status_code >= 300:
                raise self._refuse(r, "opening the revert")
            new = r.json() or {}
        return {"ref": [f"#{number}", f"#{new.get('number')}"], "detail": f"revert opened as #{new.get('number')}"}

    # ------------------------------------------------------------ open a change (the pages that render one)

    def _text(self, c, path: str, ref: str) -> str:
        """The file's text at ref, "" when it is absent there."""
        r = self._get(c, f"/repos/{self.repo}/contents/{path}", ref=ref)
        if r.status_code == 404:
            return ""
        if r.status_code >= 300:
            raise self._refuse(r, f"reading {path}")
        j = r.json() or {}
        if j.get("type") != "file" or j.get("encoding") != "base64":
            raise act.Refused(f"{path} is not a plain file in the site repository")
        try:
            return base64.b64decode(str(j.get("content", ""))).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as e:
            raise act.Refused(f"{path} is not UTF-8 text") from e

    def bump_plan(self, folder: str, cur: str, tgt: str) -> list[dict]:
        """The release bump the upgrade guide does by hand (docs/deployment/upgrade.md, step 5): in every Application
        under folder, a line `targetRevision: <cur>` becomes `<tgt>`, keeping its indent, quotes and comment; a line
        naming the site's own branch (`main`) is left alone. Refused when no file names cur, or when a layer names a
        third revision (the layers are not on one release, and the guide does not cover moving from a mix)."""
        line = re.compile(r"^(\s*targetRevision:\s*)([\"']?)([^\s\"'#]+)\2(\s*(?:#.*)?)$")
        out, mixed = [], []
        with self._bot() as c:
            for path in self.yaml_files(c, folder, self.base):
                before = self._text(c, path, self.base)
                lines, changed = before.split("\n"), False
                for i, ln in enumerate(lines):
                    m = line.match(ln)
                    if not m or m.group(3) == self.base:
                        continue
                    if m.group(3) == cur:
                        lines[i] = f"{m.group(1)}{m.group(2)}{tgt}{m.group(2)}{m.group(4)}"
                        changed = True
                    elif m.group(3) != tgt:
                        mixed.append(f"{path} ({m.group(3)})")
                if changed:
                    out.append({"path": path, "before": before, "after": "\n".join(lines),
                                "blob": self._blob(c, path, self.base)})
        if mixed:
            raise act.Refused(f"not every layer is on {cur}: {', '.join(mixed[:5])}; the guide moves one release to "
                              "another, so move these by hand first")
        if not out:
            raise act.Refused(f"no Application under {folder} on {self.base} names {cur}; nothing to move")
        return out

    def open_files(self, files: list[dict], title: str, summary: str, by: str, slug: str, requested: str = "") -> dict:
        """One commit on a new branch (as the change bot) writing each file whole, and a change for it that waits for an
        approval. Named for the result, like open_change, so asking twice opens nothing new."""
        digest = hashlib.sha256(b"".join(f["path"].encode() + b"\0" + f["after"].encode() + b"\0"
                                         for f in files)).hexdigest()
        branch = f"tockmox/console-{slug}-{digest[:12]}"
        with self._bot() as c:
            r = self._get(c, f"/repos/{self.repo}/pulls", state="open", limit=LIST_MAX)
            if r.status_code >= 300:
                raise self._refuse(r, "the list of changes")
            same = next((pr for pr in r.json() or [] if (pr.get("head") or {}).get("ref") == branch), None)
            if same:
                return {"ref": [f"#{same.get('number')}"], "number": same.get("number"),
                        "detail": f"already open as #{same.get('number')}; nothing new was opened"}
            ops = [{"operation": "update", "path": f["path"], "sha": f["blob"],
                    "content": base64.b64encode(f["after"].encode("utf-8")).decode()} for f in files]
            msg = f"{title}\n\n{summary}\n\nAsked for in the Tockmox console by {by}.\n\n{trailers(requested)}\n"
            try:
                r = c.post(f"/repos/{self.repo}/contents", json={"branch": self.base, "new_branch": branch,
                                                                  "message": msg, "files": ops})
                if r.status_code == 422 and "exist" in r.text.lower():
                    raise act.Refused(f"the branch {branch} is already in the forge with no open change: delete it "
                                      "there, or reopen its change")
                if r.status_code >= 300:
                    raise self._refuse(r, "the change's commit")
                r = c.post(f"/repos/{self.repo}/pulls", json={
                    "base": self.base, "head": branch, "title": title[:200],
                    "body": f"{summary}\n\nAsked for in the Tockmox console by {by}.\n\n{trailers(requested)}"})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer; the change may be half made (look for its branch)") from e
            if r.status_code >= 300:
                raise self._refuse(r, "opening the change")
            new = r.json() or {}
        return {"ref": [f"#{new.get('number')}"], "number": new.get("number"),
                "detail": f"opened as #{new.get('number')}, waiting for an approval"}

    def yaml_files(self, c, folder: str, ref: str) -> list[str]:
        """The .yaml and .yml files directly in folder at ref, as repository paths; [] when the folder is absent."""
        r = self._get(c, f"/repos/{self.repo}/contents/{folder}", ref=ref)
        if r.status_code == 404:
            return []
        if r.status_code >= 300 or not isinstance(r.json(), list):
            raise self._refuse(r, f"listing {folder}")
        return sorted(str(x.get("path", "")) for x in r.json()
                      if x.get("type") == "file" and str(x.get("name", "")).endswith((".yaml", ".yml")))

    def plan_change(self, path: str, edits: list, applied: str = "") -> dict:
        """What opening this change would do, without doing it: {"path", "before", "after", "blob"}. Refused when the
        file cannot be edited safely, when main already says it, or, with `applied` (the site commit Argo CD last
        applied for the layer the page read), when the file changed on main since: the page was drawn from what is
        applied, so a change merged but not applied yet would be undone by this one."""
        with self._bot() as c:
            blob = self._blob(c, path, self.base)
            if applied:
                then = self._blob(c, path, applied)
                if then != blob:
                    raise act.Refused(f"{path} has changed on {self.base} since Argo CD last applied it: wait for it to "
                                      "apply, then open this page again")
            before = self._text(c, path, self.base) if blob else ""
        after = before
        try:
            for p, v in edits:
                after = ve.set_path(after, list(p), v)
        except ve.EditRefused as e:
            raise act.Refused(f"{path}: {e}") from e
        if after == before:
            raise act.Refused(f"{self.base} already says this; there is nothing to change")
        return {"path": path, "before": before, "after": after, "blob": blob}

    def open_change(self, path: str, edits: list, title: str, summary: str, by: str, slug: str,
                    applied: str = "", requested: str = "") -> dict:
        """One commit on a new branch (as the change bot) that sets each (key path, value) in the one values file,
        leaving the rest of the file alone, and a change for it that waits for an approval. The branch is named for
        the result, so asking twice for the same change opens nothing new: the answer names the one already open."""
        plan = self.plan_change(path, edits, applied)
        digest = hashlib.sha256(path.encode() + b"\0" + plan["after"].encode()).hexdigest()
        branch = f"tockmox/console-{slug}-{digest[:12]}"
        with self._bot() as c:
            r = self._get(c, f"/repos/{self.repo}/pulls", state="open", limit=LIST_MAX)
            if r.status_code >= 300:
                raise self._refuse(r, "the list of changes")
            same = next((pr for pr in r.json() or [] if (pr.get("head") or {}).get("ref") == branch), None)
            if same:
                return {"ref": [f"#{same.get('number')}"], "number": same.get("number"),
                        "detail": f"already open as #{same.get('number')}; nothing new was opened"}
            op = {"operation": "update", "sha": plan["blob"]} if plan["blob"] else {"operation": "create"}
            op.update(path=path, content=base64.b64encode(plan["after"].encode("utf-8")).decode())
            msg = f"{title}\n\n{summary}\n\nAsked for in the Tockmox console by {by}.\n\n{trailers(requested)}\n"
            try:
                r = c.post(f"/repos/{self.repo}/contents", json={"branch": self.base, "new_branch": branch,
                                                                  "message": msg, "files": [op]})
                if r.status_code == 422 and "exist" in r.text.lower():
                    raise act.Refused(f"the branch {branch} is already in the forge with no open change: delete it "
                                      "there, or reopen its change")
                if r.status_code >= 300:
                    raise self._refuse(r, "the change's commit")
                r = c.post(f"/repos/{self.repo}/pulls", json={
                    "base": self.base, "head": branch, "title": title[:200],
                    "body": f"{summary}\n\nAsked for in the Tockmox console by {by}. It changes only {path}, and in "
                            f"it only what this page set; the rest of the file is as it was.\n\n{trailers(requested)}"})
            except httpx.HTTPError as e:
                raise act.Refused("the forge did not answer; the change may be half made (look for its branch)") from e
            if r.status_code >= 300:
                raise self._refuse(r, "opening the change")
            new = r.json() or {}
        return {"ref": [f"#{new.get('number')}"], "number": new.get("number"),
                "detail": f"opened as #{new.get('number')}, waiting for an approval"}

    def _blob(self, c, path: str, ref: str) -> str:
        """The blob sha of path at ref, or "" when it is absent there."""
        r = self._get(c, f"/repos/{self.repo}/contents/{path}", ref=ref)
        if r.status_code == 404:
            return ""
        if r.status_code >= 300:
            raise self._refuse(r, f"reading {path}")
        j = r.json()
        if not isinstance(j, dict) or j.get("type") != "file":
            raise act.Refused(f"{path} is not a plain file; revert it by hand")
        return str(j.get("sha", ""))

    def _content(self, c, path: str, ref: str) -> str:
        r = self._get(c, f"/repos/{self.repo}/contents/{path}", ref=ref)
        if r.status_code >= 300:
            raise self._refuse(r, f"reading {path} before the change")
        j = r.json() or {}
        if j.get("type") != "file" or j.get("encoding") != "base64":
            raise act.Refused(f"{path} is not a plain file; revert it by hand")
        raw = base64.b64decode(str(j.get("content", "")))
        return base64.b64encode(raw).decode()

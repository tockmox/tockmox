#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# forge-approver-watch.py: who is in the built-in forge's approvers team but no longer
# in the console's admin group, as Prometheus metrics. It changes nothing.
#
# WHY. The forge maps the admin group onto its `approvers` team only when a person signs
# in. A person taken out of the admin group (or deactivated) in the identity provider can
# no longer sign in, so the removal never runs and they stay an approver indefinitely
# (measured on Forgejo 15.0.11, 2026-11-02). The ruling of 2026-11-04 is detect and alert,
# and a person acts: nothing in the cluster holds a credential that can change the team.
# So this reads, every INTERVAL seconds, with two read-only credentials, and says who.
#
# WHAT IT EXPOSES on LISTEN (GET /metrics):
#   tockmox_forge_approvers_check_ok              1 when both reads were clean, else 0
#   tockmox_forge_approvers_outside_group         how many team members are not active
#                                                 members of the group (only when ok)
#   tockmox_forge_approver_outside_group_info{user, since}
#                                                 one per such person; since = when this
#                                                 watcher first saw them outside (unix s)
#   tockmox_forge_approval_by_outside_approver{user, pr}
#                                                 one per open pull request that carries a
#                                                 standing approval from such a person
#   tockmox_forge_approvers_last_success_timestamp_seconds
#
# THE FAIL-SAFE. Nobody is judged on a bad read. An identity provider that errors, answers
# anything but 2xx, returns a missing group, or returns a group with no active member while
# the team still has people, makes check_ok 0 and drops every per-person series, so an outage
# never reads as "everyone was removed". An empty group beside an empty team is a fresh site
# (nobody named an admin yet, nobody signed in): clean, with nobody to judge (Jeff,
# 2026-11-10, after the first lab install read check_ok 0 there). The alert on
# check_ok 0 is a different one (TockmoxForgeApproversCheckDown), not a removal alert.
# A deactivated user counts as removed (ruled 2026-11-04, R4).
#
# Names compare directly: forge accounts are created from the identity provider's
# username at first sign-in (no account linking), so a team member's login is the group
# member's username.
#
# It only ever sends GET. Run once and print with --once (the tests do).
#
# Settings, from the environment (never argv, so no token is in a process listing):
#   AUTHENTIK_URL        e.g. http://authentik-server.tockmox-authentik.svc
#   AUTHENTIK_TOKEN_FILE a file holding a token that may view the one group
#   ADMIN_GROUP          default tockmox-admins
#   FORGE_URL            e.g. http://tockmox-forge-http.tockmox-forge.svc:3000
#   FORGE_TOKEN_FILE     a file holding a token scoped read:organization, read:repository. Its account
#                        is in the organisation's Owners team: the forge shows a team's members only to
#                        that team and the owners. The token's scopes are what keep it from changing anything.
#   FORGE_ORG, FORGE_TEAM, FORGE_REPO   default tockmox, approvers, site
#   INTERVAL             seconds between checks, default 60
#   LISTEN               host:port, default 0.0.0.0:9470
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

TIMEOUT = 20
PAGE = 50


class ReadError(Exception):
    pass


def env(name, default=None):
    v = os.environ.get(name, default)
    if v is None or v == "":
        raise SystemExit(f"forge-approver-watch: {name} is not set")
    return v


def token(path):
    try:
        with open(path) as fh:
            t = fh.readline().strip()
    except OSError as e:
        raise ReadError(f"cannot read the token file {path}: {e.strerror}")
    if not t:
        raise ReadError(f"the token file {path} is empty")
    return t


def get(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            if not 200 <= r.status < 300:
                raise ReadError(f"GET {url}: HTTP {r.status}")
            body = r.read()
    except urllib.error.HTTPError as e:
        raise ReadError(f"GET {url}: HTTP {e.code}")
    except (urllib.error.URLError, OSError) as e:
        raise ReadError(f"GET {url}: {getattr(e, 'reason', e)}")
    try:
        return json.loads(body)
    except ValueError:
        raise ReadError(f"GET {url}: the answer is not JSON")


def active_admins(base, tok, group):
    """The usernames of the group's ACTIVE members. Raises on anything not clean."""
    q = urllib.parse.urlencode({"name": group, "include_users": "true"})
    data = get(f"{base.rstrip('/')}/api/v3/core/groups/?{q}", {"Authorization": f"Bearer {tok}"})
    results = data.get("results") if isinstance(data, dict) else None
    if not isinstance(results, list):
        raise ReadError("the identity provider's group answer has no results list")
    match = [g for g in results if isinstance(g, dict) and g.get("name") == group]
    if len(match) != 1:
        raise ReadError(f"the group {group!r} was found {len(match)} times, not once")
    users = match[0].get("users_obj")
    if not isinstance(users, list):
        raise ReadError(f"the group {group!r} came back without its members")
    names = {u.get("username") for u in users if isinstance(u, dict) and u.get("is_active") is True}
    names.discard(None)
    # An empty set is returned, not refused: check() decides. A fresh site has nobody in the
    # admin group and nobody in the team, and that is a clean state with nobody to judge.
    return names


def paged(base, path, hdr):
    out, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        items = get(f"{base}{path}{sep}limit={PAGE}&page={page}", hdr)
        if not isinstance(items, list):
            raise ReadError(f"GET {path}: expected a list")
        out.extend(items)
        if len(items) < PAGE:
            return out
        page += 1
        if page > 200:
            raise ReadError(f"GET {path}: more than {200 * PAGE} items")


def forge_state(base, tok, org, team, repo):
    """(team member logins, {pr number: set of logins with a standing approval})."""
    base = f"{base.rstrip('/')}/api/v1"
    hdr = {"Authorization": f"token {tok}"}
    # The organisation's team list, not the team search: the forge limits a search to the teams the
    # caller is in (unless a site admin), so a watcher outside the team would find nothing. Listing
    # the team's members needs the caller to be in that team or an owner of the organisation, which
    # is why the watcher's account is in Owners and its one token is read-only (ruled 2026-11-11).
    teams = paged(base, f"/orgs/{org}/teams", hdr)
    ids = [t.get("id") for t in teams if isinstance(t, dict) and t.get("name") == team]
    if len(ids) != 1:
        raise ReadError(f"the team {org}/{team} was found {len(ids)} times, not once")
    members = {m.get("login") for m in paged(base, f"/teams/{ids[0]}/members", hdr) if isinstance(m, dict)}
    members.discard(None)
    approvals = {}
    for pr in paged(base, f"/repos/{org}/{repo}/pulls?state=open", hdr):
        n = pr.get("number") if isinstance(pr, dict) else None
        if not isinstance(n, int):
            continue
        # The latest review per reviewer decides: an approval later replaced by a change
        # request or dismissed does not stand.
        latest = {}
        reviews = [rv for rv in paged(base, f"/repos/{org}/{repo}/pulls/{n}/reviews", hdr) if isinstance(rv, dict)]
        for rv in sorted(reviews, key=lambda r: r.get("id") if isinstance(r.get("id"), int) else 0):
            who = (rv.get("user") or {}).get("login")
            # A comment-only review leaves an earlier approval standing, so only these two count.
            if who and rv.get("state") in ("APPROVED", "REQUEST_CHANGES"):
                latest[who] = rv
        standing = {w for w, rv in latest.items()
                    if rv.get("state") == "APPROVED" and not rv.get("dismissed") and not rv.get("stale")}
        if standing:
            approvals[n] = standing
    return members, approvals


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.since = {}
        self.text = "tockmox_forge_approvers_check_ok 0\n"
        self.last_success = None

    def check(self, cfg, now=None):
        now = int(now if now is not None else time.time())
        try:
            admins = active_admins(cfg["AUTHENTIK_URL"], token(cfg["AUTHENTIK_TOKEN_FILE"]), cfg["ADMIN_GROUP"])
            members, approvals = forge_state(cfg["FORGE_URL"], token(cfg["FORGE_TOKEN_FILE"]),
                                             cfg["FORGE_ORG"], cfg["FORGE_TEAM"], cfg["FORGE_REPO"])
            if not admins and members:
                # An admin group with no active member while the team still has people is
                # not a state a running site gets into on purpose: read it as a bad answer
                # (an outage, a permission that hides members), never as "all removed".
                raise ReadError(f"the group {cfg['ADMIN_GROUP']!r} has no active member while the "
                                f"{cfg['FORGE_TEAM']!r} team has {len(members)}")
        except ReadError as e:
            print(f"forge-approver-watch: check not ok, nobody judged: {e}", file=sys.stderr, flush=True)
            with self.lock:
                lines = ["tockmox_forge_approvers_check_ok 0"]
                if self.last_success is not None:
                    lines.append(f"tockmox_forge_approvers_last_success_timestamp_seconds {self.last_success}")
                self.text = "\n".join(lines) + "\n"
            return False
        outside = sorted(members - admins)
        with self.lock:
            for u in list(self.since):
                if u not in outside:
                    del self.since[u]
            for u in outside:
                self.since.setdefault(u, now)
            self.last_success = now
            lines = ["tockmox_forge_approvers_check_ok 1",
                     f"tockmox_forge_approvers_outside_group {len(outside)}",
                     f"tockmox_forge_approvers_last_success_timestamp_seconds {now}"]
            for u in outside:
                lines.append(f'tockmox_forge_approver_outside_group_info{{user="{esc(u)}",since="{self.since[u]}"}} 1')
            for n in sorted(approvals):
                for u in sorted(approvals[n] & set(outside)):
                    lines.append(f'tockmox_forge_approval_by_outside_approver{{user="{esc(u)}",pr="{n}"}} 1')
            self.text = "\n".join(lines) + "\n"
        if outside:
            print(f"forge-approver-watch: outside the group but still approvers: {', '.join(outside)}",
                  file=sys.stderr, flush=True)
        return True

    def metrics(self):
        with self.lock:
            return self.text


def config():
    return {
        "AUTHENTIK_URL": env("AUTHENTIK_URL"),
        "AUTHENTIK_TOKEN_FILE": env("AUTHENTIK_TOKEN_FILE"),
        "ADMIN_GROUP": env("ADMIN_GROUP", "tockmox-admins"),
        "FORGE_URL": env("FORGE_URL"),
        "FORGE_TOKEN_FILE": env("FORGE_TOKEN_FILE"),
        "FORGE_ORG": env("FORGE_ORG", "tockmox"),
        "FORGE_TEAM": env("FORGE_TEAM", "approvers"),
        "FORGE_REPO": env("FORGE_REPO", "site"),
    }


def main(argv):
    cfg = config()
    state = State()
    if argv[1:] == ["--once"]:
        ok = state.check(cfg)
        sys.stdout.write(state.metrics())
        return 0 if ok else 1
    if argv[1:]:
        print("usage: forge-approver-watch.py [--once]", file=sys.stderr)
        return 2
    interval = int(env("INTERVAL", "60"))
    host, _, port = env("LISTEN", "0.0.0.0:9470").rpartition(":")

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path.split("?")[0] not in ("/metrics", "/healthz"):
                self.send_response(404); self.end_headers(); return
            body = (state.metrics() if self.path.startswith("/metrics") else "ok\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer((host or "0.0.0.0", int(port)), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    while True:
        state.check(cfg)
        time.sleep(interval)


if __name__ == "__main__":
    sys.exit(main(sys.argv))

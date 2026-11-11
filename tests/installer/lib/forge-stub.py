#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for what install/forge-offsite-copy.sh talks to, for the hermetic dump tests.

One loopback server, three roles, told apart by path:

  /api/v1/...   the forge's REST API, answering the calls the nightly dump makes, with the
                shape and the compact encoding Forgejo uses (field order matters to the
                dump's review-id check, so it is the forge's order)
  /s3/<bucket>/<key>   an S3-compatible bucket, path style, in memory (PUT, GET, HEAD; the
                request signature is not checked: the dump's correctness does not depend on it)
  /tockmox-bkt/<key>   the same store, as the bucket tockmox-bkt at the endpoint's root, for a
                client whose endpoint takes no path (forge-restore.sh and its rebuild drill)
  anything else  git over smart HTTP, served by `git http-backend` from ROOT: the forge's
                repository at /tockmox/site.git and an off-site remote at /remote/site.git

Usage: forge-stub.py ROOT PORTFILE.  The chosen port is written to PORTFILE once it listens.
With ADMIN=1 it also plays the forge's administration API that bootstrap-forge.sh drives (organisations,
users, teams, tokens with their scopes, branch protection, OAuth2 applications, and a bare repository it
`git init`s so the installer can push), keeping its state in ROOT/forge.json so a second run finds what the
first made. A token is enforced the way the forge does it: it needs the scope for the route AND the user must
be able to see the thing (a member of a team of the organisation, a team that holds the repository).
Knobs, read from the environment at start: PRS (how many pull requests, default 3),
FAIL=pulls (that endpoint answers 500), BADREV=1 (reviews come in a field order the dump
cannot read, as if the forge changed its format), CORRUPT=1 (a stored dump reads back with
a byte added, as if the bucket damaged it).
"""
import http.server
import json as _json
import os
import re
import subprocess
import sys
import urllib.parse

ROOT = sys.argv[1]
PRS = int(os.environ.get("PRS", "3"))
STORE = {}


def dumps(o):
    return _json.dumps(o, separators=(",", ":"))


def user(n):
    return {"id": 7, "login": n, "html_url": "http://forge/" + n}


def repo():
    return {"id": 1, "name": "site", "full_name": "tockmox/site", "html_url": "http://forge/tockmox/site", "private": True}


def pr(n):
    u = "http://forge/tockmox/site/pulls/%d" % n
    return {"id": 100 + n, "url": u, "number": n, "user": user("bot"), "title": "change %d" % n, "state": "closed",
            "html_url": u, "diff_url": u + ".diff",
            "base": {"label": "main", "repo": repo()}, "head": {"label": "c%d" % n, "repo": repo()}}


def review(n, i):
    u = "http://forge/tockmox/site/pulls/%d" % n
    return {"id": i, "user": user("approver"), "team": None, "state": "APPROVED", "body": "ok", "commit_id": "abc",
            "stale": False, "official": True, "dismissed": False, "comments_count": 1,
            "submitted_at": "2026-11-03T00:00:00Z", "updated_at": "2026-11-03T00:00:00Z",
            "html_url": "%s#issuecomment-%d" % (u, i), "pull_request_url": u}


def review_comment(n, i):
    return {"id": 900 + i, "body": "nit", "diff_hunk": "@@ -1 +1 @@", "path": "a.yaml", "user": user("approver"),
            "pull_request_review_id": i, "pull_request_url": "http://forge/tockmox/site/pulls/%d" % n}


def issue_comment(n):
    return {"id": 500 + n, "html_url": "http://forge/tockmox/site/pulls/%d#issuecomment-%d" % (n, 500 + n),
            "issue_url": "http://forge/tockmox/site/issues/%d" % n, "user": user("bot"), "body": "hello"}


def page(items, q):
    p = int(q.get("page", ["1"])[0])
    n = int(q.get("limit", ["50"])[0])
    return items[(p - 1) * n:p * n]


def json_load(path):
    with open(path) as fh:
        return _json.load(fh)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def api(self, a, q):
        base = "/repos/tockmox/site"
        if a == "/version":
            return self.send(200, b'{"version":"15.0.11+gitea-1.22.0"}')
        if a == base:
            return self.send(200, dumps(repo()).encode())
        if a == base + "/pulls":
            if os.environ.get("FAIL") == "pulls":
                return self.send(500, b"{}")
            return self.send(200, dumps(page([pr(n) for n in range(1, PRS + 1)], q)).encode())
        if a == base + "/issues/comments":
            return self.send(200, dumps(page([issue_comment(n) for n in range(1, PRS + 1)], q)).encode())
        m = re.fullmatch(base + r"/pulls/(\d+)/reviews", a)
        if m:
            n = int(m.group(1))
            r = review(n, n * 10)
            if os.environ.get("BADREV"):
                r = {"user": r["user"], "id": r["id"], "pull_request_url": r["pull_request_url"]}
            return self.send(200, dumps(page([r], q)).encode())
        m = re.fullmatch(base + r"/pulls/(\d+)/reviews/(\d+)/comments", a)
        if m:
            return self.send(200, dumps([review_comment(int(m.group(1)), int(m.group(2)))]).encode())
        return self.send(404, b'{"message":"not found"}')

    # move-forge (POST a pull request, read it back, PATCH the repository archived). MOVE=merge makes
    # the stand-in merge the change the first time it is read, as an approver would; MOVE=wait never does.
    def write_api(self, a):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
        d = _json.loads(body or b"{}")
        if self.command == "POST" and a == "/repos/tockmox/site/pulls":
            os.makedirs(os.path.join(ROOT, "moves"), exist_ok=True)
            n = 100 + len(os.listdir(os.path.join(ROOT, "moves"))) + 1
            rec = {"number": n, "state": "open", "merged": False, "title": d.get("title"), "body": d.get("body", ""),
                   "head": {"ref": d.get("head")}}
            with open(os.path.join(ROOT, "moves", "%d.json" % n), "w") as fh:
                _json.dump(rec, fh)
            return self.send(201, dumps(rec).encode())
        if self.forge_issues(a, d):
            return
        if self.command == "PATCH" and a == "/repos/tockmox/site":
            with open(os.path.join(ROOT, "archived"), "w") as fh:
                fh.write("true" if d.get("archived") else "false")
            return self.send(200, dumps(repo()).encode())
        return self.send(404, b'{"message":"not found"}')

    # Labels and issues, kept in ROOT/issues.json so a test can read them back.
    def issue_state(self):
        path = os.path.join(ROOT, "issues.json")
        if os.path.exists(path):
            return json_load(path)
        return {"labels": [], "issues": []}

    def issue_save(self, st):
        with open(os.path.join(ROOT, "issues.json"), "w") as fh:
            _json.dump(st, fh)

    def forge_issues(self, a, d):
        base = "/repos/tockmox/site"
        st = self.issue_state()
        if self.command == "POST" and a == base + "/labels":
            lab = {"id": len(st["labels"]) + 1, "name": d.get("name"), "color": d.get("color")}
            st["labels"].append(lab)
            self.issue_save(st)
            self.send(201, dumps(lab).encode())
            return True
        if self.command == "POST" and a == base + "/issues":
            ids = d.get("labels") or []
            rec = {"number": len(st["issues"]) + 1, "title": d.get("title"), "body": d.get("body"),
                   "state": "open", "labels": [x for x in st["labels"] if x["id"] in ids]}
            st["issues"].append(rec)
            self.issue_save(st)
            self.send(201, dumps(rec).encode())
            return True
        m = re.fullmatch(base + r"/issues/(\d+)", a)
        if self.command == "PATCH" and m:
            for rec in st["issues"]:
                if rec["number"] == int(m.group(1)):
                    if d.get("state"):
                        rec["state"] = d["state"]
                    self.issue_save(st)
                    self.send(200, dumps(rec).encode())
                    return True
            self.send(404, b'{"message":"not found"}')
            return True
        return False

    def forge_issues_get(self, a, q):
        base = "/repos/tockmox/site"
        if a == base + "/labels":
            self.send(200, dumps(page(self.issue_state()["labels"], q)).encode())
            return True
        if a == base + "/issues":
            items = self.issue_state()["issues"]
            want = [x for v in q.get("labels", []) for x in v.split(",") if x]
            if want:
                items = [i for i in items if any(l["name"] in want for l in i["labels"])]
            self.send(200, dumps(page(items, q)).encode())
            return True
        return False

    def move_pr(self, n):
        path = os.path.join(ROOT, "moves", "%d.json" % n)
        if not os.path.exists(path):
            return self.send(404, b"{}")
        rec = json_load(path)
        mode = os.environ.get("MOVE", "")
        if os.path.exists(os.path.join(ROOT, "move-mode")):   # a test switches it between runs
            mode = open(os.path.join(ROOT, "move-mode")).read().strip()
        if mode == "merge" and not rec["merged"]:
            bare = os.path.join(ROOT, "tockmox", "site.git")
            head = subprocess.run(["git", "--git-dir", bare, "rev-parse", "refs/heads/" + rec["head"]["ref"]],
                                  capture_output=True, text=True).stdout.strip()
            subprocess.run(["git", "--git-dir", bare, "update-ref", "refs/heads/main", head], check=True)
            rec.update(state="closed", merged=True)
            with open(path, "w") as fh:
                _json.dump(rec, fh)
        if mode == "close" and rec["state"] == "open":
            rec.update(state="closed")
            with open(path, "w") as fh:
                _json.dump(rec, fh)
        return self.send(200, dumps(rec).encode())

    # ---- ADMIN=1: the administration API bootstrap-forge.sh drives. State in ROOT/forge.json.
    def fstate(self):
        path = os.path.join(ROOT, "forge.json")
        if os.path.exists(path):
            return json_load(path)
        return {"orgs": {}, "repos": {}, "users": {}, "teams": {}, "tokens": {}, "protections": {}, "oauth": [], "next": 1}

    def fsave(self, st):
        with open(os.path.join(ROOT, "forge.json"), "w") as fh:
            _json.dump(st, fh)

    def who(self, st):
        h = self.headers.get("Authorization", "")
        if h.startswith("token "):
            for u, toks in st["tokens"].items():
                for rec in toks.values():
                    if rec["sha1"] == h[6:]:
                        return ("token", u, rec["scopes"])
            return None
        if h.startswith("Basic "):
            return ("admin", "tockmox-admin", None)
        return None

    def admin(self, a, q):
        n = int(self.headers.get("Content-Length", 0) or 0)
        d = _json.loads(self.rfile.read(n) or b"{}") if n else {}
        st = self.fstate()
        me = self.who(st)
        m = self.command
        if me is None:
            return self.send(401, b'{"message":"Only signed in user is allowed to call APIs."}')
        if me[0] == "token":
            return self.admin_token(st, me, a, q, m)
        nxt = st["next"]
        if m == "GET" and a == "/version":
            return self.send(200, b'{"version":"15.0.11+gitea-1.22.0"}')
        r = re.fullmatch(r"/orgs/([^/]+)", a)
        if r and m == "GET":
            return self.send(200 if r.group(1) in st["orgs"] else 404, dumps({"username": r.group(1)}).encode())
        if a == "/orgs" and m == "POST":
            st["orgs"][d["username"]] = {}
            owners = nxt
            st["teams"][str(owners)] = {"id": owners, "name": "Owners", "org": d["username"], "permission": "owner", "members": ["tockmox-admin"], "repos": []}
            st["next"] = nxt + 1
            self.fsave(st)
            return self.send(201, dumps({"username": d["username"]}).encode())
        r = re.fullmatch(r"/repos/([^/]+)/([^/]+)", a)
        if r and m == "GET":
            return self.send(200 if "%s/%s" % r.groups() in st["repos"] else 404, dumps({"name": r.group(2)}).encode())
        r = re.fullmatch(r"/orgs/([^/]+)/repos", a)
        if r and m == "POST":
            full = "%s/%s" % (r.group(1), d["name"])
            st["repos"][full] = {}
            bare = os.path.join(ROOT, full + ".git")
            os.makedirs(os.path.dirname(bare), exist_ok=True)
            subprocess.run(["git", "init", "-q", "--bare", "-b", "main", bare], check=True)
            subprocess.run(["git", "--git-dir", bare, "config", "http.receivepack", "true"], check=True)
            self.fsave(st)
            return self.send(201, dumps({"name": d["name"]}).encode())
        r = re.fullmatch(r"/users/([^/]+)", a)
        if r and m == "GET":
            return self.send(200 if r.group(1) in st["users"] else 404, dumps({"login": r.group(1)}).encode())
        if a == "/admin/users" and m == "POST":
            st["users"][d["username"]] = {"is_admin": False}
            self.fsave(st)
            return self.send(201, dumps({"login": d["username"]}).encode())
        r = re.fullmatch(r"/orgs/([^/]+)/teams/search", a)
        if r and m == "GET":
            want = q.get("q", [""])[0]
            hit = [t for t in st["teams"].values() if t["org"] == r.group(1) and want.lower() in t["name"].lower()]
            return self.send(200, dumps({"ok": True, "data": [{"id": t["id"], "name": t["name"], "permission": t["permission"]} for t in hit]}).encode())
        r = re.fullmatch(r"/orgs/([^/]+)/teams", a)
        if r and m == "POST":
            st["teams"][str(nxt)] = {"id": nxt, "name": d["name"], "org": r.group(1), "permission": d.get("permission"), "members": [], "repos": []}
            st["next"] = nxt + 1
            self.fsave(st)
            return self.send(201, dumps({"id": nxt, "name": d["name"]}).encode())
        r = re.fullmatch(r"/teams/(\d+)/repos/([^/]+)/([^/]+)", a)
        if r and m == "PUT":
            t = st["teams"][r.group(1)]
            full = "%s/%s" % (r.group(2), r.group(3))
            if full not in t["repos"]:
                t["repos"].append(full)
            self.fsave(st)
            return self.send(204)
        r = re.fullmatch(r"/teams/(\d+)/members/([^/]+)", a)
        if r and m == "PUT":
            if r.group(2) not in st["users"] and r.group(2) != "tockmox-admin":
                return self.send(404, b'{"message":"user does not exist"}')
            t = st["teams"][r.group(1)]
            if r.group(2) not in t["members"]:
                t["members"].append(r.group(2))
            self.fsave(st)
            return self.send(204)
        r = re.fullmatch(r"/teams/(\d+)/members", a)
        if r and m == "GET":
            return self.send(200, dumps([{"login": u} for u in st["teams"][r.group(1)]["members"]]).encode())
        r = re.fullmatch(r"/users/([^/]+)/tokens", a)
        if r and m == "POST":
            u = r.group(1)
            toks = st["tokens"].setdefault(u, {})
            if d["name"] in toks:
                return self.send(400, b'{"message":"access token name has been used already"}')
            toks[d["name"]] = {"id": nxt, "sha1": "tok.%s.%d" % (u, nxt), "scopes": d.get("scopes", [])}
            st["next"] = nxt + 1
            self.fsave(st)
            return self.send(201, dumps({"id": nxt, "name": d["name"], "sha1": toks[d["name"]]["sha1"], "scopes": d.get("scopes", [])}).encode())
        if r and m == "GET":
            toks = st["tokens"].get(r.group(1), {})
            return self.send(200, dumps([{"id": v["id"], "name": k, "scopes": v["scopes"]} for k, v in toks.items()]).encode())
        r = re.fullmatch(r"/users/([^/]+)/tokens/([^/]+)", a)
        if r and m == "DELETE":
            ok = st["tokens"].get(r.group(1), {}).pop(r.group(2), None)
            self.fsave(st)
            return self.send(204 if ok else 404)
        r = re.fullmatch(r"/repos/([^/]+)/([^/]+)/branch_protections(/main)?", a)
        if r:
            key = "%s/%s" % (r.group(1), r.group(2))
            if m == "DELETE":
                gone = st["protections"].pop(key, None)
                self.fsave(st)
                return self.send(204 if gone else 404)
            if m == "POST":
                st["protections"][key] = d
                self.fsave(st)
                return self.send(201, dumps(d).encode())
            if m == "GET":
                rule = st["protections"].get(key)
                return self.send(200 if rule else 404, dumps(rule or {}).encode())
        if a == "/user/applications/oauth2":
            if m == "GET":
                return self.send(200, dumps(st["oauth"]).encode())
            if m == "POST":
                rec = {"id": nxt, "name": d["name"], "client_id": "cid.%d" % nxt, "client_secret": "cs.%d" % nxt,
                       "redirect_uris": d["redirect_uris"], "confidential_client": True}
                st["oauth"].append(rec)
                st["next"] = nxt + 1
                self.fsave(st)
                return self.send(201, dumps(rec).encode())
        r = re.fullmatch(r"/user/applications/oauth2/(\d+)", a)
        if r and m == "DELETE":
            st["oauth"] = [x for x in st["oauth"] if x["id"] != int(r.group(1))]
            self.fsave(st)
            return self.send(204)
        if a == "/repos/tockmox/site/push_mirrors":
            return self.send(200, b"[]")
        return self.send(404, dumps({"message": "stub: no route for %s %s" % (m, a)}).encode())

    def admin_token(self, st, me, a, q, m):
        _, user, scopes = me
        in_teams = [t for t in st["teams"].values() if user in t["members"]]
        r = re.fullmatch(r"/orgs/([^/]+)/teams/search", a)
        r2 = re.fullmatch(r"/teams/(\d+)/members", a)
        r3 = re.fullmatch(r"/repos/([^/]+)/([^/]+)(/.*)?", a)
        if m != "GET" or not (r or r2 or r3):
            return self.send(403, b'{"message":"token does not have at least one of required scope(s)"}')
        need = "organization" if (r or r2) else "repository"
        if not any(sc in ("read:" + need, "write:" + need) for sc in scopes):
            return self.send(403, dumps({"message": "token does not have at least one of required scope(s): [read:%s]" % need}).encode())
        if r:
            if not any(t["org"] == r.group(1) for t in in_teams):
                return self.send(404, b'{"message":"organization not found"}')
            want = q.get("q", [""])[0]
            hit = [t for t in st["teams"].values() if t["org"] == r.group(1) and want.lower() in t["name"].lower()]
            return self.send(200, dumps({"ok": True, "data": [{"id": t["id"], "name": t["name"]} for t in hit]}).encode())
        if r2:
            t = st["teams"].get(r2.group(1))
            if not t or not any(x["org"] == t["org"] for x in in_teams):
                return self.send(404, b'{"message":"team not found"}')
            return self.send(200, dumps([{"login": u} for u in t["members"]]).encode())
        full = "%s/%s" % (r3.group(1), r3.group(2))
        if not any(full in t["repos"] for t in in_teams):
            return self.send(404, b'{"message":"repository not found"}')
        return self.send(200, b"[]")

    def route(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path
        if p.startswith("/tockmox-bkt/"):
            # The same bucket at the endpoint's root, for a client that takes an endpoint
            # with no path (forge-restore.sh, whose rebuild drill writes its record here).
            p = "/s3" + p
        if p.startswith("/s3/"):
            k = p[4:]
            if self.command == "PUT":
                STORE[k] = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                return self.send(200)
            if k in STORE:
                body = STORE[k]
                if os.environ.get("CORRUPT") and k.endswith(".tar.gz"):
                    body = body + b"x"
                return self.send(200, body, "application/octet-stream")
            return self.send(404, b"<Error>NoSuchKey</Error>")
        if p.startswith("/api/v1") and os.environ.get("ADMIN"):
            return self.admin(p[7:], q)
        if p.startswith("/api/v1") and self.command in ("POST", "PATCH"):
            return self.write_api(p[7:])
        if p.startswith("/api/v1"):
            m = re.fullmatch(r"/repos/tockmox/site/pulls/(\d+)", p[7:])
            if m and os.path.exists(os.path.join(ROOT, "moves")):
                return self.move_pr(int(m.group(1)))
            if p[7:] == "/repos/tockmox/site/pulls" and os.path.exists(os.path.join(ROOT, "moves")):
                return self.send(200, dumps([json_load(os.path.join(ROOT, "moves", f)) for f in sorted(os.listdir(os.path.join(ROOT, "moves")))]).encode())
            if self.command == "GET" and self.forge_issues_get(p[7:], q):
                return
            return self.api(p[7:], q)
        env = dict(os.environ, GIT_PROJECT_ROOT=ROOT, GIT_HTTP_EXPORT_ALL="1", PATH_INFO=p, QUERY_STRING=u.query,
                   REQUEST_METHOD=self.command, CONTENT_TYPE=self.headers.get("Content-Type", ""),
                   REMOTE_USER="stub", REMOTE_ADDR="127.0.0.1")
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        if self.headers.get("Transfer-Encoding") == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        env["CONTENT_LENGTH"] = str(len(body))
        if self.headers.get("Content-Encoding"):
            env["HTTP_CONTENT_ENCODING"] = self.headers["Content-Encoding"]
        backend = subprocess.run(["git", "--exec-path"], capture_output=True, text=True).stdout.strip() + "/git-http-backend"
        r = subprocess.run([backend], input=body, env=env, capture_output=True)
        head, _, out = r.stdout.partition(b"\r\n\r\n")
        code, hs = 200, []
        for line in head.split(b"\r\n"):
            k, _, v = line.partition(b": ")
            if k.lower() == b"status":
                code = int(v.split()[0])
            else:
                hs.append((k.decode(), v.decode()))
        self.send_response(code)
        for k, v in hs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_PUT = do_POST = do_HEAD = do_PATCH = do_DELETE = route


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()

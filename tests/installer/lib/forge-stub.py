#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for what install/forge-offsite-copy.sh talks to, for the hermetic dump tests.

One loopback server, three roles, told apart by path:

  /api/v1/...   the forge's REST API, answering the calls the nightly dump makes, with the
                shape and the compact encoding Forgejo uses (field order matters to the
                dump's review-id check, so it is the forge's order)
  /s3/<bucket>/<key>   an S3-compatible bucket, path style, in memory (PUT, GET, HEAD; the
                request signature is not checked: the dump's correctness does not depend on it)
  anything else  git over smart HTTP, served by `git http-backend` from ROOT: the forge's
                repository at /tockmox/site.git and an off-site remote at /remote/site.git

Usage: forge-stub.py ROOT PORTFILE.  The chosen port is written to PORTFILE once it listens.
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

    def route(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path
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
        if p.startswith("/api/v1"):
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

    do_GET = do_PUT = do_POST = do_HEAD = route


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()

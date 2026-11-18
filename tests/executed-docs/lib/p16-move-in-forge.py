#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The verdicts of paths/P16-move-in-forge.sh, kept apart from the path so that move-in-rows-test.sh can show each
one red on a planted input, with no cluster.

Every verdict subcommand reads standard input and prints ONE line, which the path compares with the value it expects.
A read that cannot be judged prints "unreadable: ..." and is never a pass. A repository is one repository in any
spelling (https or ssh, with or without .git, any case in the host), as the installer reads it.

  root --from URL --in URL [--root NAME]
                     stdin: Argo CD's Applications (kubectl -o json). Where the root Application reads its source:
                     "the external repository", "the built-in forge", "another repository: X", or "absent".
  revision [--root NAME]
                     stdin: the same. The revision the root is synced to.
  settled [--accept NAME[,NAME]]
                     stdin: the same. "N Synced and Healthy" when every Application is, otherwise "not settled: ..."
                     naming the first three that are not. No Application at all is unreadable. An Application named
                     with --accept (the path's lab-only DNS row, the move's --accept-unsettled) does not hold the
                     verdict back: when it is the only one not Synced and Healthy, the verdict is "the rest Synced and
                     Healthy; accepted as it is: NAME is SYNC/HEALTH", never the "N Synced and Healthy" of a clean read.
  reads --url URL    stdin: the same. "K read it": how many Applications name URL in a source.
  moved --before FILE --from URL --in URL
                     stdin: the Applications now; FILE: the same list before the move. "every Application that read
                     the external repository reads the built-in forge (K)", or what is wrong: one that still reads
                     the external repository, one that is gone, one that reads neither. K of 0 is unreadable: a move
                     that moved nothing proves nothing.
  pruned --before FILE
                     stdin: the Applications now; FILE: before. "nothing pruned (N resources)" when every resource
                     each Application managed before is still managed by it, otherwise "pruned: ..." naming the first.
                     No resource before is unreadable.
  credential --url URL
                     stdin: one Argo CD repository Secret (kubectl -o json). "names URL's repository", "names another
                     repository", or unreadable.
  ca-trusted --url URL --ca FILE
                     stdin: Argo CD's argocd-tls-certs-cm (kubectl -o json). "holds the CA under the URL's host" when
                     the entry keyed by URL's host name (Argo CD's own key: the host part, no port) holds FILE's
                     certificate, otherwise "no entry for the URL's host" or "another certificate under the URL's
                     host". A CA file with no certificate in it is unreadable.
  conditions [--root NAME]
                     stdin: Argo CD's Applications. The root Application's own .status.conditions on one line, each
                     "TYPE: message", or "none". What the path prints when a settle times out, so a run that never
                     settles says why in Argo CD's words.

Helpers, not verdicts (the path's GLUE):

  rewrite --old URL --new URL DIR
                     every `repoURL:` line in DIR's YAML files that names --old's repository names --new instead, the
                     quoting and any comment kept. Prints "rewrote L line(s) in F file(s)"; exit 1 when it rewrote none.
  argo-secret --name N --url URL --credentials FILE
                     stdout: an Argo CD repository Secret (JSON) for URL with FILE's two lines as user and token, for
                     `kubectl apply -f -`, so the token is on no command line.
  argo-ca --url URL --ca FILE
                     stdout: a merge patch (JSON) for argocd-tls-certs-cm that adds FILE's certificate under URL's host
                     name and names no other key, for `kubectl patch --type merge`, so every other entry is kept.
  scrub --host H     stdin to stdout, every H replaced by <external forge>. Empty H changes nothing.
"""
import argparse
import base64
import json
import os
import re
import sys
from urllib.parse import urlsplit

URL = re.compile(r'^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)(?::\d+)?[:/](.+?)(?:\.git)?/?$')
LINE = re.compile(r'^(\s*(?:-\s+)?repoURL:\s*)(["\']?)([^\s"\'#]+)\2(\s*(?:#.*)?)$')


def norm(u):
    u = (u or "").strip().strip('"').strip("'")
    m = URL.match(u)
    return (m.group(1).lower() + "/" + m.group(2)) if m else u


def one(line):
    print(line)
    return 0


def unreadable(why):
    return one("unreadable: " + why)


def apps_of(text):
    """{name: app} from a kubectl list, or None when it is not one."""
    try:
        doc = json.loads(text)
    except ValueError:
        return None
    if not isinstance(doc, dict) or doc.get("kind") == "Status" or not isinstance(doc.get("items"), list):
        return None
    out = {}
    for a in doc["items"]:
        try:
            out[a["metadata"]["name"]] = a
        except (KeyError, TypeError):
            return None
    return out


def sources(a):
    s = a.get("spec", {}) or {}
    return [norm(x.get("repoURL", "")) for x in ([s["source"]] if s.get("source") else []) + (s.get("sources") or [])]


def state(a):
    st = a.get("status", {}) or {}
    return (st.get("sync", {}) or {}).get("status", "?"), (st.get("health", {}) or {}).get("status", "?")


def resources(a):
    return {(r.get("group", ""), r.get("kind", ""), r.get("namespace", ""), r.get("name", ""))
            for r in (a.get("status", {}) or {}).get("resources", []) or []}


def read_apps(stream):
    text = stream.read()
    if not text.strip():
        return None, "an empty read"
    apps = apps_of(text)
    if apps is None:
        return None, "not a list of Applications"
    return apps, ""


def v_root(a):
    apps, why = read_apps(sys.stdin)
    if apps is None:
        return unreadable(why)
    r = apps.get(a.root)
    if r is None:
        return one("absent")
    src = sources(r)
    if norm(a.in_url) in src:
        return one("the built-in forge")
    if norm(a.from_url) in src:
        return one("the external repository")
    return one("another repository: " + (" ".join(src) or "none"))


def v_revision(a):
    apps, why = read_apps(sys.stdin)
    if apps is None:
        return unreadable(why)
    r = apps.get(a.root)
    if r is None:
        return unreadable("no Application " + a.root)
    rev = ((r.get("status", {}) or {}).get("sync", {}) or {}).get("revision", "")
    return one(rev) if rev else unreadable("the root reports no revision")


def v_settled(a):
    apps, why = read_apps(sys.stdin)
    if apps is None:
        return unreadable(why)
    if not apps:
        return unreadable("no Application at all")
    accept = set(x for x in (a.accept or "").split(",") if x)
    off = [(n, "%s is %s/%s" % ((n,) + state(x))) for n, x in sorted(apps.items()) if state(x) != ("Synced", "Healthy")]
    bad = [t for n, t in off if n not in accept]
    if bad:
        return one("not settled: " + "; ".join(bad[:3]))
    if off:
        return one("the rest Synced and Healthy; accepted as it is: " + "; ".join(t for _, t in off))
    return one("%d Synced and Healthy" % len(apps))


def v_reads(a):
    apps, why = read_apps(sys.stdin)
    if apps is None:
        return unreadable(why)
    return one("%d read it" % sum(1 for x in apps.values() if norm(a.url) in sources(x)))


def load_before(path):
    try:
        with open(path, encoding="utf-8") as f:
            return apps_of(f.read())
    except OSError:
        return None


def v_moved(a):
    now, why = read_apps(sys.stdin)
    if now is None:
        return unreadable(why)
    before = load_before(a.before)
    if before is None:
        return unreadable("the list before the move cannot be read")
    f, i = norm(a.from_url), norm(a.in_url)
    movers = [n for n, x in sorted(before.items()) if f in sources(x)]
    if not movers:
        return unreadable("no Application read the external repository before the move")
    bad = []
    for n in movers:
        if n not in now:
            bad.append("%s is gone" % n)
        elif f in sources(now[n]):
            bad.append("%s still reads the external repository" % n)
        elif i not in sources(now[n]):
            bad.append("%s reads neither" % n)
    bad += ["%s reads the external repository" % n for n, x in sorted(now.items()) if n not in movers and f in sources(x)]
    if bad:
        return one("not moved: " + "; ".join(bad[:3]))
    return one("every Application that read the external repository reads the built-in forge (%d)" % len(movers))


def v_pruned(a):
    now, why = read_apps(sys.stdin)
    if now is None:
        return unreadable(why)
    before = load_before(a.before)
    if before is None:
        return unreadable("the list before the move cannot be read")
    total = sum(len(resources(x)) for x in before.values())
    if total == 0:
        return unreadable("no Application managed any resource before the move")
    bad = []
    for n, x in sorted(before.items()):
        lost = resources(x) - (resources(now[n]) if n in now else set())
        if lost:
            bad.append("%s lost %d, e.g. %s" % (n, len(lost), "/".join(p for p in sorted(lost)[0] if p)))
    return one("pruned: " + "; ".join(bad[:3]) if bad else "nothing pruned (%d resources)" % total)


def v_credential(a):
    text = sys.stdin.read()
    try:
        s = json.loads(text)
        url = base64.b64decode(s["data"]["url"]).decode()
    except (ValueError, KeyError, TypeError):
        return unreadable("not a repository Secret with a url")
    return one("names the URL's repository" if norm(url) == norm(a.url) else "names another repository")


PEM = re.compile(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", re.S)


def url_host(u):
    """The host name Argo CD keys argocd-tls-certs-cm by: the URL's host part, no user and no port, as written."""
    return urlsplit((u or "").strip()).netloc.rsplit("@", 1)[-1].split(":")[0]


def pems(text):
    return ["".join(x.split()) for x in PEM.findall(text or "")]


def read_ca(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    return text if pems(text) else None


def v_ca_trusted(a):
    ca = read_ca(a.ca)
    if ca is None:
        return unreadable("the CA file holds no certificate")
    host = url_host(a.url)
    if not host:
        return unreadable("the URL names no host")
    try:
        cm = json.loads(sys.stdin.read())
        data = cm.get("data") or {}
        if cm.get("kind") == "Status" or not isinstance(data, dict):
            raise ValueError
    except (ValueError, AttributeError):
        return unreadable("not a ConfigMap")
    if host not in data:
        return one("no entry for the URL's host")
    held = pems(data[host])
    return one("holds the CA under the URL's host" if all(p in held for p in pems(ca))
               else "another certificate under the URL's host")


def v_conditions(a):
    apps, why = read_apps(sys.stdin)
    if apps is None:
        return unreadable(why)
    r = apps.get(a.root)
    if r is None:
        return unreadable("no Application " + a.root)
    cs = (r.get("status", {}) or {}).get("conditions") or []
    out = "; ".join("%s: %s" % (c.get("type", "?"), " ".join(str(c.get("message", "")).split())) for c in cs)
    return one(out[:600] if out else "none")


def h_argo_ca(a):
    ca = read_ca(a.ca)
    if ca is None:
        sys.exit("argo-ca: the CA file holds no certificate")
    host = url_host(a.url)
    if not host:
        sys.exit("argo-ca: the URL names no host")
    print(json.dumps({"data": {host: ca}}))
    return 0


def h_rewrite(a):
    old, new = norm(a.old), a.new
    files = lines = 0
    for d, dirs, names in os.walk(a.dir):
        dirs[:] = [x for x in dirs if x != ".git"]
        for n in names:
            if not n.endswith((".yaml", ".yml")):
                continue
            p = os.path.join(d, n)
            try:
                with open(p, encoding="utf-8") as f:
                    src = f.read()
            except (OSError, UnicodeDecodeError):
                continue
            out, hit = [], 0
            for line in src.split("\n"):
                m = LINE.match(line)
                if m and norm(m.group(3)) == old:
                    line = m.group(1) + m.group(2) + new + m.group(2) + m.group(4)
                    hit += 1
                out.append(line)
            if hit:
                with open(p, "w", encoding="utf-8") as f:
                    f.write("\n".join(out))
                files += 1
                lines += hit
    print("rewrote %d line(s) in %d file(s)" % (lines, files))
    return 0 if lines else 1


def h_argo_secret(a):
    try:
        with open(a.credentials, encoding="utf-8") as f:
            ls = [x.strip() for x in f.read().splitlines() if x.strip()]
    except OSError:
        sys.exit("argo-secret: cannot read the credentials file")
    if len(ls) < 2:
        sys.exit("argo-secret: the credentials file has no two lines")
    enc = lambda s: base64.b64encode(s.encode()).decode()
    print(json.dumps({"apiVersion": "v1", "kind": "Secret",
                      "metadata": {"name": a.name, "namespace": "argocd",
                                   "labels": {"argocd.argoproj.io/secret-type": "repository"}},
                      "type": "Opaque",
                      "data": {"type": enc("git"), "url": enc(a.url), "username": enc(ls[0]), "password": enc(ls[1])}}))
    return 0


def h_scrub(a):
    text = sys.stdin.read()
    sys.stdout.write(re.sub(re.escape(a.host), "<external forge>", text, flags=re.I) if a.host else text)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("root")
    p.add_argument("--from", dest="from_url", required=True)
    p.add_argument("--in", dest="in_url", required=True)
    p.add_argument("--root", default="tockmox-root")
    sub.add_parser("revision").add_argument("--root", default="tockmox-root")
    sub.add_parser("settled").add_argument("--accept", default="")
    sub.add_parser("reads").add_argument("--url", required=True)
    p = sub.add_parser("moved")
    p.add_argument("--before", required=True)
    p.add_argument("--from", dest="from_url", required=True)
    p.add_argument("--in", dest="in_url", required=True)
    sub.add_parser("pruned").add_argument("--before", required=True)
    sub.add_parser("credential").add_argument("--url", required=True)
    for n in ("ca-trusted", "argo-ca"):
        p = sub.add_parser(n)
        p.add_argument("--url", required=True)
        p.add_argument("--ca", required=True)
    sub.add_parser("conditions").add_argument("--root", default="tockmox-root")
    p = sub.add_parser("rewrite")
    p.add_argument("--old", required=True)
    p.add_argument("--new", required=True)
    p.add_argument("dir")
    p = sub.add_parser("argo-secret")
    p.add_argument("--name", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--credentials", required=True)
    sub.add_parser("scrub").add_argument("--host", default="")
    a = ap.parse_args()
    return {"root": v_root, "revision": v_revision, "settled": v_settled, "reads": v_reads, "moved": v_moved,
            "pruned": v_pruned, "credential": v_credential, "ca-trusted": v_ca_trusted, "conditions": v_conditions,
            "rewrite": h_rewrite, "argo-secret": h_argo_secret, "argo-ca": h_argo_ca, "scrub": h_scrub}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())

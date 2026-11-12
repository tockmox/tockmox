#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A stand-in cluster for the full-run cases of tests/installer/bootstrap-forge-tests.sh.

Objects are kept as JSON files, $FAKE_STATE/objs/<namespace>/<Kind>/<name>.json, so a test can read what
the installer applied and a second run finds what the first made. It answers only the calls bootstrap-forge.sh
makes; anything else exits 2 and says so, because a stand-in that answers everything would let the script call
anything and still pass. The calls are logged (arguments only, never stdin) in $FAKE_STATE/calls.log.

Test helper:  fake-kubectl.py @get NAMESPACE KIND NAME PATH   (parts split by /) prints one value; a Secret's data is decoded.
"""
import base64
import json
import os
import re
import sys

import yaml

S = os.environ["FAKE_STATE"]
OBJ = os.path.join(S, "objs")


def path(ns, kind, name):
    return os.path.join(OBJ, ns or "_", kind, name + ".json")


def load(ns, kind, name):
    p = path(ns, kind, name)
    return json.load(open(p)) if os.path.exists(p) else None


def save(doc, default_ns):
    ns = (doc.get("metadata") or {}).get("namespace") or default_ns
    p = path(ns, doc["kind"], doc["metadata"]["name"])
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        json.dump(doc, fh, sort_keys=True)


def ns_exists(name):
    return os.path.exists(os.path.join(OBJ, "_ns", name))


def make_ns(name):
    os.makedirs(os.path.join(OBJ, "_ns"), exist_ok=True)
    open(os.path.join(OBJ, "_ns", name), "w").close()


def jp(doc, expr):
    """The few jsonpath forms bootstrap-forge.sh uses."""
    m = re.fullmatch(r"\{(.*)\}", expr)
    if not m:
        return None
    parts = re.findall(r"(?:\\.|[^.])+", m.group(1))
    cur = doc
    for part in parts:
        part = part.replace("\\.", ".")
        if not part:
            continue
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur if isinstance(cur, str) else None


def main(argv):
    if argv[0] == "@get":
        _, ns, kind, name, p = argv
        doc = load(ns, kind, name)
        v = doc
        for part in p.split("/"):
            v = v[part] if isinstance(v, dict) and part in v else None
        if kind == "Secret" and p.startswith("data/") and v:
            v = base64.b64decode(v).decode()
        sys.stdout.write("" if v is None else str(v))
        return 0
    with open(os.path.join(S, "calls.log"), "a") as fh:
        fh.write("kubectl %s\n" % " ".join(argv))
    ns, rest, i = "", [], 0
    while i < len(argv):
        if argv[i] == "--context":
            i += 2
        elif argv[i] in ("-n", "--namespace"):
            ns = argv[i + 1]
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    out = next((r.split("=", 1)[1] for r in rest if r.startswith("jsonpath=")), None)
    for k, r in enumerate(rest):
        if r == "-o" and k + 1 < len(rest):
            out = rest[k + 1]
    verb = rest[0] if rest else ""
    if rest[:2] == ["config", "current-context"]:
        print("lab-test")
        return 0
    if rest[:2] == ["config", "view"]:
        print("https://192.0.2.10:6443")
        return 0
    if verb == "get" and rest[1] == "namespace":
        if len(rest) == 2:
            return 0
        return 0 if ns_exists(rest[2]) else 1
    if verb == "create" and rest[1] == "namespace":
        make_ns(rest[2])
        return 0
    if verb == "get" and rest[1] == "secret":
        doc = load(ns, "Secret", rest[2])
        if doc is None:
            sys.stderr.write('Error from server (NotFound): secrets "%s" not found\n' % rest[2])
            return 1
        if out == "name":
            print("secret/" + rest[2])
            return 0
        if out and out.startswith("jsonpath="):
            v = jp(doc, out[len("jsonpath="):])
            sys.stdout.write(v or "")
            return 0
        return 0
    if verb == "get" and rest[1] == "deploy":
        sys.stdout.write("code.forgejo.org/forgejo/forgejo:15.0.11")
        return 0
    if verb == "get" and rest[1] == "pod":
        sys.stdout.write("tockmox-forge-0")
        return 0
    if verb == "get" and rest[1] == "pvc":
        return 1
    if verb == "create" and rest[1] == "configmap":
        name = rest[2]
        data = {}
        for r in rest:
            m = re.match(r"--from-file=([^=]+)=(.*)", r)
            if m:
                data[m.group(1)] = open(m.group(2)).read()
        print(yaml.safe_dump({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": ns}, "data": data}))
        return 0
    if verb == "apply":
        for doc in yaml.safe_load_all(sys.stdin.read()):
            if isinstance(doc, dict) and doc.get("kind"):
                save(doc, ns)
        return 0
    if verb == "rollout":
        return 0
    if verb == "exec":
        tail = rest[rest.index("--") + 1:] if "--" in rest else []
        if tail[:1] == ["grep"]:
            print("2")
            return 0
        if tail[:1] == ["cat"]:
            print("[security]\nSECRET_KEY = fake.not.a.key")
            return 0
        return 1   # `forgejo admin auth list`: no sign-in source yet, so the script says so and goes on
    sys.stderr.write("fake kubectl: unhandled: %s\n" % " ".join(argv))
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

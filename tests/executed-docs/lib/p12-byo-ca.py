#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verdicts for P12's rows: docs/administration/bring-your-own-ca.md, run.

P12 runs the page's blocks, keeps their output, and asks this module one
question per row. Each subcommand reads ONE artefact on stdin and prints ONE
verdict line. The row's expected value is a fixed phrase or a value P12 held
independently (the fingerprint of the CA it generated); a verdict that is
anything else is the reason the row is red.

  p12-byo-ca.py fingerprint                              < openssl output
  p12-byo-ca.py namespace                                < the step 1 block's output
  p12-byo-ca.py enddate [--now EPOCH]                    < the step 2 block's output
  p12-byo-ca.py sealed --name N --ns NS                  < a SealedSecret (YAML)
  p12-byo-ca.py certs --issuer NAME                      < the step 5 certificate table
  p12-byo-ca.py issuers --issuer NAME --secret NAME      < the step 5 issuer table
  p12-byo-ca.py flag --word WORD                         < any text: "present" or "absent"
  p12-byo-ca.py count --line TEXT                        < any text: how many lines equal TEXT

Why a module and not shell: the same predicates run in byo-ca-test.sh against
green and red fixtures, so each row is shown able to go red without a cluster.
Input that cannot be read is a verdict beginning "unreadable" or "none", never
a traceback and never a pass: an empty read must not look like a healthy one.

The shapes this module reads are quoted from the page and from openssl and
kubeseal, not from a live run:
  - openssl x509 -fingerprint -sha256   "sha256 Fingerprint=AA:BB:..." (OpenSSL 3;
                                        "SHA256 Fingerprint=" in 1.1)
  - openssl x509 -enddate               "notAfter=Nov 10 21:00:00 2036 GMT"
  - kubeseal --format yaml              kind SealedSecret, metadata.name and
                                        namespace, spec.encryptedData, spec.template.type
  - kubectl custom-columns              a header row, then whitespace-separated columns

Exit 0 with a verdict, 2 for a usage error.
"""
import calendar
import re
import sys
import time


def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def fingerprint(text):
    m = re.search(r"(?i)sha256 fingerprint=([0-9A-F:]+)", text)
    return m.group(1).upper() if m else "none"


def namespace(text):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    # a Kubernetes namespace is a DNS label; anything else on the line is an error message
    names = [l for l in lines if re.fullmatch(r"[a-z0-9]([-a-z0-9]*[a-z0-9])?", l)]
    if len(lines) == 0:
        return "none"
    if len(lines) != 1 or len(names) != 1:
        return "not exactly one namespace: %d line(s)" % len(lines)
    return names[0]


def enddate(text, now):
    m = re.search(r"notAfter=(\w{3}) +(\d+) (\d\d):(\d\d):(\d\d) (\d{4}) GMT", text)
    if not m:
        return "none"
    mon, day, hh, mm, ss, yr = m.groups()
    try:
        end = calendar.timegm(time.strptime("%s %s %s:%s:%s %s" % (mon, day, hh, mm, ss, yr), "%b %d %H:%M:%S %Y"))
    except ValueError:
        return "unreadable end date"
    return "future" if end > now else "past"


def sealed(text, name, ns):
    kinds = re.findall(r"(?m)^kind: (\S+)\s*$", text)
    if kinds != ["SealedSecret"]:
        return "not exactly one SealedSecret (kinds: %s)" % (",".join(kinds) or "none")
    md = re.search(r"(?m)^metadata:\n((?:[ ]+.*\n?)+)", text)
    if not md:
        return "no metadata"
    got_name = re.search(r"(?m)^  name: (\S+)", md.group(1))
    got_ns = re.search(r"(?m)^  namespace: (\S+)", md.group(1))
    if not got_name or got_name.group(1) != name:
        return "sealed name is %s, not %s" % (got_name.group(1) if got_name else "absent", name)
    if not got_ns or got_ns.group(1) != ns:
        return "sealed namespace is %s, not %s" % (got_ns.group(1) if got_ns else "absent", ns)
    enc = re.search(r"(?m)^  encryptedData:\n((?:    .*\n?)+)", text)
    keys = {}
    if enc:
        for l in enc.group(1).splitlines():
            k = re.match(r"    ([^:\s]+): (\S+)", l)
            if k:
                keys[k.group(1)] = k.group(2)
    for want in ("tls.crt", "tls.key"):
        if not keys.get(want):
            return "encryptedData has no %s" % want
    ty = re.search(r"(?m)^    type: (\S+)", text)
    if not ty or ty.group(1) != "kubernetes.io/tls":
        return "template type is %s, not kubernetes.io/tls" % (ty.group(1) if ty else "absent")
    return "sealed tls Secret %s in %s" % (name, ns)


def rows(text):
    lines = [l for l in text.splitlines() if l.strip()]
    return [l.split() for l in lines[1:]] if len(lines) > 1 else []


def certs(text, issuer):
    r = rows(text)
    if not r:
        return "no Certificate rows"
    bad = [x for x in r if len(x) < 4 or x[2] != "True" or x[3] != issuer]
    if bad:
        return "%d of %d not True on %s: %s" % (len(bad), len(r), issuer, "; ".join("/".join(x[:4]) for x in bad[:4]))
    return "all %d True on %s" % (len(r), issuer)


def issuers(text, issuer, secret):
    r = rows(text)
    if not r:
        return "no ClusterIssuer rows"
    cas = [x for x in r if len(x) >= 2 and x[1] not in ("<none>", "<nil>")]
    if len(cas) != 1:
        return "%d CA issuer row(s): %s" % (len(cas), "; ".join("/".join(x[:2]) for x in cas) or "none")
    if cas[0][0] != issuer or cas[0][1] != secret:
        return "the one CA issuer is %s/%s" % (cas[0][0], cas[0][1])
    return "one CA issuer: %s with %s" % (issuer, secret)


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    text = sys.stdin.read()
    if cmd == "fingerprint":
        print(fingerprint(text))
    elif cmd == "namespace":
        print(namespace(text))
    elif cmd == "enddate":
        print(enddate(text, int(arg("--now", str(int(time.time()))))))
    elif cmd == "sealed":
        print(sealed(text, arg("--name", ""), arg("--ns", "")))
    elif cmd == "certs":
        print(certs(text, arg("--issuer", "")))
    elif cmd == "issuers":
        print(issuers(text, arg("--issuer", ""), arg("--secret", "")))
    elif cmd == "flag":
        print("present" if arg("--word", "\0") in text else "absent")
    elif cmd == "count":
        want = arg("--line", None)
        if want is None:
            return 2
        print(sum(1 for l in text.splitlines() if l.strip() == want))
    else:
        return 2
    return 0


sys.exit(main())

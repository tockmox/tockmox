# SPDX-License-Identifier: Apache-2.0
"""posture-probe COMMAND

  collect        black-box collector; runs in a source namespace as its real ServiceAccount
  differential   the in-cluster differential Job (the gate); exit 0 clean, 1 could not run, 2 drift
  gate O I [--declared D --targets T]
                 the same engine over files, for CI; the report goes to stdout
  validate R     check a stored report against the published schema; exit 0 valid, 1 not
  standin        a listener that serves an empty directory, for the declared targets
"""
import json, os, sys


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0 if len(argv) >= 2 else 1
    cmd, rest = argv[1], argv[2:]
    if cmd == "collect":
        from . import blackbox
        blackbox.main()
        return 0
    if cmd == "differential":
        from . import aggregate
        return aggregate.main()
    if cmd == "gate":
        from . import differential
        return differential.main(["differential"] + rest)
    if cmd == "validate":
        from . import schema
        errs = schema.validate(json.load(open(rest[0])), rest[1] if len(rest) > 1 else None)
        for e in errs:
            print(e)
        print("valid" if not errs else "INVALID: %d error(s)" % len(errs))
        return 0 if not errs else 1
    if cmd == "standin":
        import functools, http.server
        port = int(os.environ.get("STANDIN_PORT", "8080"))
        root = os.environ.get("STANDIN_DIR", "/tmp/standin")
        os.makedirs(root, exist_ok=True)
        h = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
        http.server.ThreadingHTTPServer(("0.0.0.0", port), h).serve_forever()
        return 0
    sys.stderr.write("unknown command %r\n" % cmd)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))

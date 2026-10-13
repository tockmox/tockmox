#!/usr/bin/env python3
"""Read rendered YAML on stdin; report Ingresses that terminate no TLS.

Emits, line-oriented, so the shell needs no YAML parser of its own:
    TOTAL <n>          documents examined that were Ingresses
    BAD <name> (<hosts>)
    ERR <detail>       a document that could not be parsed

TWO FAILURES THIS FILE EXISTS TO NOT REPEAT, both found on 2026-09-13 while
writing it, both of which produced a GREEN result from a check that had
examined nothing or nearly nothing:

1. The parser was first inlined as `python3 - <<'PY'` inside a command
   substitution. That makes the heredoc the SCRIPT and leaves stdin empty, so
   it read zero documents and the gate printed "clean".

2. Then it used `yaml.safe_load_all`, which is a GENERATOR: one undecodable
   document anywhere in the stream aborts the whole iteration. A chart
   rendering `- =` (the YAML `value` tag) killed the parse partway, the shell
   swallowed the traceback with `|| true`, and that entire chart was silently
   dropped from the count while the gate still said clean.

So: documents are parsed ONE AT A TIME, a failure is reported as ERR rather
than raised, and the caller is expected to treat any ERR as a failure. A parser
that cannot read its input must never look the same as one that read it and
found nothing wrong.
"""
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ingress_tls: PyYAML is required\n")
    sys.exit(2)


class Loader(yaml.SafeLoader):
    """SafeLoader that tolerates tags helm output legitimately contains."""


# `=` is the YAML "value" tag. Rendered chart content carries it, and SafeLoader
# has no constructor for it, which is what aborted the stream.
Loader.add_constructor(
    "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
)


def documents(text):
    """Yield (ok, doc_or_error) per document, never raising."""
    for chunk in text.split("\n---"):
        if not chunk.strip():
            continue
        try:
            yield True, yaml.load(chunk, Loader=Loader)
        except Exception as exc:  # noqa: BLE001 - reporting, not handling
            first = next((l for l in chunk.splitlines() if l.strip()), "")
            yield False, "%s :: near %r" % (type(exc).__name__, first[:70])


def main():
    total = 0
    bad = []
    errs = []
    for ok, item in documents(sys.stdin.read()):
        if not ok:
            errs.append(item)
            continue
        if not isinstance(item, dict) or item.get("kind") != "Ingress":
            continue
        total += 1
        meta = item.get("metadata") or {}
        spec = item.get("spec") or {}
        # `tls: []` is not a tls block. A grep for "tls:" cannot tell the two
        # apart, which is why this parses instead of matching text.
        if not (spec.get("tls") or []):
            hosts = [r["host"] for r in (spec.get("rules") or []) if r.get("host")]
            bad.append("%s (%s)" % (meta.get("name", "?"), ", ".join(hosts) or "no host"))

    print("TOTAL %d" % total)
    for b in bad:
        print("BAD %s" % b)
    for e in errs:
        print("ERR %s" % e)


if __name__ == "__main__":
    main()

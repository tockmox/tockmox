# SPDX-License-Identifier: Apache-2.0
"""Fuzz the short-path redirect (app/redirects.py): nothing a requester types may move the browser off the console's host.

The input is what reaches redirects.target() in main.py: the raw request path after /<app_id>, and the raw query,
both decoded from the request's bytes as latin-1. The host always comes from config, so the properties are:

  1. target() either returns or raises Refused; any other exception is a crash.
  2. A returned Location starts with the configured URL plus "/", so the authority cannot change.
  3. It is printable ASCII with no space: no CR or LF to split the header, and no tab or newline for a browser to drop.
  4. Its path has no dot segment, in any spelling a browser treats as one ("..", ".%2e", "%2E%2e", ...).

Run it in ClusterFuzzLite (.clusterfuzzlite/), or locally with atheris installed:
    python3 tockmox-ui/fuzz/redirects_fuzzer.py -max_total_time=60
"""
import os
import sys

import atheris

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

with atheris.instrument_imports():
    from app import redirects

BASES = ("https://grafana.int.example", "https://console.example:8443", "https://apps.example/sub")
DOTS = (".", "..", "%2e", ".%2e", "%2e.", "%2e%2e")


def check(base: str, rest: str, query: str) -> None:
    try:
        out = redirects.target(base, rest, query)
    except redirects.Refused:
        return
    assert out.startswith(base + "/"), (base, rest, query, out)
    assert all(0x21 <= ord(c) <= 0x7E for c in out), (rest, query, out)
    path = out[len(base):].split("?", 1)[0].split("#", 1)[0]
    for seg in path.split("/"):
        assert seg.lower() not in DOTS, (rest, out, seg)


def test_one_input(data: bytes) -> None:
    fdp = atheris.FuzzedDataProvider(data)
    base = BASES[fdp.ConsumeIntInRange(0, len(BASES) - 1)]
    as_path = fdp.ConsumeBool()   # main.py hands target() what follows /<app_id>: usually "/...", but any raw bytes
    query = fdp.ConsumeBytes(fdp.ConsumeIntInRange(0, 64)).decode("latin-1")
    rest = fdp.ConsumeBytes(fdp.remaining_bytes()).decode("latin-1")
    if as_path and not rest.startswith("/"):
        rest = "/" + rest
    check(base, rest, query)


def main() -> None:
    atheris.Setup(sys.argv, test_one_input)
    atheris.Fuzz()


if __name__ == "__main__":
    main()

# SPDX-License-Identifier: Apache-2.0
"""Short paths: tockmox.<domain>/<id>[/<rest>] -> the console's own host.

The host ALWAYS comes from config. <rest> is accepted only if it is a plain
path, and is re-encoded segment by segment, so nothing a requester types can
change where the browser lands (no //host, no backslash, no scheme, no ..).
"""
from __future__ import annotations

import re
from urllib.parse import quote, unquote

_SEG_OK = re.compile(r"^[A-Za-z0-9._~!$&'()*+,;=:@%-]*$")


class Refused(ValueError):
    pass


def target(base_url: str, rest: str, query: str = "") -> str:
    if rest in ("", "/"):
        out = base_url + "/"
    else:
        # Decode once to see what the browser would see, then judge THAT.
        decoded = unquote(rest)
        if any(c in decoded for c in ("\\", "\r", "\n", "\t", "\x00")):
            raise Refused("control or backslash")
        if not decoded.startswith("/") or decoded.startswith("//"):
            raise Refused("not a plain path")
        if "://" in decoded:
            raise Refused("embedded scheme")
        if any(s in (".", "..") for s in decoded.split("/")[1:]):
            raise Refused("dot segment")
        raw = rest.split("/")[1:]
        if any(unquote(s) in (".", "..") for s in raw):
            raise Refused("dot segment")
        # re-encode from the RAW segments so an escaped slash inside a segment survives
        enc = "/".join(quote(s, safe="-._~!$&'()*+,;=:@%") for s in raw)
        out = base_url + "/" + enc
    if query:
        # request.url.query is the RAW (percent-encoded) query, so it cannot hold a literal
        # CR/LF; quote() keeps escapes as escapes, so nothing can break out of the header.
        out += "?" + quote(query, safe="=&-._~%+,:@/")
    return out

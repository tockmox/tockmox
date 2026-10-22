#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Count established pf states that show an administrator can still get in.

Reads `pfctl -ss` on stdin. A state counts when it is TCP, established, one end is on an
administration port, and the other end is inside one of the administrator networks. The
firewall role uses the count as the confirmation of a change to the administrator rules: if the
administrator who is applying the change still has a session after the rules loaded, the rules let
administrators in.

Prints the number of matching states and exits 0, whatever it read.
"""
import argparse
import ipaddress
import re
import sys


def endpoint(token):
    """Return (ip, port) from 'a.b.c.d:port', 'v6addr[port]' or '[v6addr]:port', else None."""
    m = re.match(r"^\[?([0-9A-Fa-f:.]+)\]?(?:\[(\d+)\]|:(\d+))$", token)
    if not m:
        return None
    ip = m.group(1)
    port = m.group(2) or m.group(3)
    try:
        return ipaddress.ip_address(ip), int(port)
    except ValueError:
        return None


def count(lines, ports, networks):
    n = 0
    for line in lines:
        words = line.split()
        if "tcp" not in words or not words[-1].startswith("ESTABLISHED"):
            continue
        i = words.index("tcp")
        # tcp <end> <arrow> <end> [<arrow> <end>] <state>; NAT adds a second pair, so look at the first two.
        if len(words) < i + 4:
            continue
        a = endpoint(words[i + 1])
        b = endpoint(words[i + 3])
        if not a or not b:
            continue
        for local, remote in ((a, b), (b, a)):
            if local[1] in ports and any(remote[0] in net for net in networks if remote[0].version == net.version):
                n += 1
                break
    return n


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ports", required=True, help="comma-separated administration ports")
    p.add_argument("--cidrs", required=True, help="comma-separated administrator networks")
    args = p.parse_args()
    try:
        ports = {int(x) for x in args.ports.split(",") if x}
        networks = [ipaddress.ip_network(x, strict=False) for x in args.cidrs.split(",") if x]
    except ValueError:
        print(0)
        return 0
    print(count(sys.stdin.read().splitlines(), ports, networks))
    return 0


if __name__ == "__main__":
    sys.exit(main())

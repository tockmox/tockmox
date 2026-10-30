# SPDX-License-Identifier: Apache-2.0
"""A DNS responder for tests/agent-egress/proxy-proof.sh: answers A queries from a fixed table, NXDOMAIN otherwise.

    python3 fake_dns.py PORT name=1.2.3.4 [name=...]

Stdlib only, UDP only, one question per query: enough for Smokescreen's resolver, nothing more."""
import socket
import struct
import sys


def main():
    port = int(sys.argv[1])
    table = dict(a.split("=", 1) for a in sys.argv[2:])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    while True:
        q, addr = s.recvfrom(512)
        tid, flags, qd = struct.unpack(">HHH", q[:6])
        i, labels = 12, []
        while q[i]:
            labels.append(q[i + 1:i + 1 + q[i]].decode())
            i += 1 + q[i]
        qtype = struct.unpack(">H", q[i + 1:i + 3])[0]
        question = q[12:i + 5]
        name = ".".join(labels).lower()
        ip = table.get(name)
        if ip and qtype == 1:
            ans = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 30, 4) + socket.inet_aton(ip)
            s.sendto(struct.pack(">HHHHHH", tid, 0x8180, 1, 1, 0, 0) + question + ans, addr)
        elif ip:      # a name we know, a type we do not serve (AAAA): an empty answer, not NXDOMAIN
            s.sendto(struct.pack(">HHHHHH", tid, 0x8180, 1, 0, 0, 0) + question, addr)
        else:
            s.sendto(struct.pack(">HHHHHH", tid, 0x8183, 1, 0, 0, 0) + question, addr)


if __name__ == "__main__":
    main()

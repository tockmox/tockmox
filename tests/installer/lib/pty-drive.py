#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run a command under a pseudo-terminal and feed it answers.

Why this exists at all: `install/tockmox-install.sh` reads its interactive
answers with `read -r ans </dev/tty`, which is the right call ... it keeps the
prompts working when stdin is a pipe. The cost is that the interactive path
cannot be driven by `printf '...' | script.sh`, so for as long as this project
has existed there was no way to test it, and it was never tested. It shipped
broken: a variable used as a prompt default was assigned below the prompt that
read it, `set -u` fired, and nine answered questions ended in
`DEF_SC: unbound variable` with no site repository written.

Stdlib only, on purpose. A test of the bootstrap installer that first requires
installing a test runtime is the same mistake the installer itself refuses to
make (see its own header).

    pty-drive.py --answers FILE [--timeout N] -- CMD [ARG...]

FILE is one answer per line; a blank line means "accept the default", which is
what a bare Enter does. Lines beginning `#` are comments and are NOT sent.

Writes the full transcript to stdout and exits with the child's exit status.
A timeout exits 124, matching `timeout(1)`, so a hang is distinguishable from
a refusal. That distinction matters here: the installer's `ask` loop bounds
itself at five rejected attempts precisely because an unbounded one spun
forever, and a test that reports "hung" when the real answer is "refused five
times" would hide the thing worth knowing.
"""
import argparse
import os
import pty
import select
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--answers", required=True)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd[1:] if args.cmd and args.cmd[0] == "--" else args.cmd
    if not cmd:
        sys.stderr.write("pty-drive.py: no command given\n")
        return 2

    with open(args.answers, encoding="utf-8") as fh:
        answers = [
            line.rstrip("\n")
            for line in fh
            if not line.startswith("#")
        ]

    pid, fd = pty.fork()
    if pid == 0:
        # Child. A deterministic, narrow terminal: colour off via NO_COLOR so the
        # transcript a test greps is the text and not the escape sequences.
        os.environ["NO_COLOR"] = "1"
        os.environ["TERM"] = "dumb"
        try:
            os.execvp(cmd[0], cmd)
        except OSError as exc:  # pragma: no cover - exec failure in child
            sys.stderr.write("pty-drive.py: exec failed: %s\n" % exc)
            os._exit(127)

    # Parent. Write every answer up front. The tty line discipline buffers them
    # and each `read` consumes one line, so this needs no prompt matching ...
    # which is the fragile part of every other approach to this, and the reason
    # a prompt-matching first draft of this file mis-answered the ninth question
    # when two prompts landed in one read.
    payload = "".join(a + "\n" for a in answers).encode()
    try:
        os.write(fd, payload)
    except OSError:
        pass  # child already gone; the transcript below will say why

    chunks = []
    deadline = time.time() + args.timeout
    timed_out = False
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            timed_out = True
            break
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.5))
        if not ready:
            # No output ready. Reap if the child is gone; otherwise keep waiting.
            wpid, _ = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                break
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break  # EIO on the master is how a pty reports the child exited
        if not data:
            break
        chunks.append(data)

    transcript = b"".join(chunks).decode("utf-8", errors="replace")
    # The pty echoes what we wrote, so the transcript already shows the answers
    # next to the prompts they answered. That is wanted: a reader of a failed
    # run needs to see what was typed.
    sys.stdout.write(transcript)
    sys.stdout.flush()

    if timed_out:
        try:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
        except OSError:
            pass
        sys.stderr.write("pty-drive.py: timed out after %.0fs\n" % args.timeout)
        return 124

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        return 0
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main())

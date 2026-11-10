#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# What P09 needs when the p09 lane gives its install an off-site copy
# (TOCKMOX_P09_OFFSITE=git). Sourced by paths/P09-install-md-end-to-end.sh and by
# offsite-copy-test.sh; it does nothing by itself.
#
#   offsite_block [ca]   stdin: install.md's bootstrap-forge block as printed.
#                        stdout: the same block with the git destination added the
#                        way the page says to add one ("Add one of these to the
#                        command"), on its own line before --dry-run. With `ca`
#                        the remote's CA is passed too. The values are shell
#                        variables the caller exports, never text in the block:
#                        the block is printed in the run report, and the report
#                        of a public repository's workflow is public.
#   offsite_scrub        stdin to stdout, with the off-site host
#                        (TOCKMOX_P09_OFFSITE_SCRUB) replaced by <off-site host>.
#                        The installer names the remote it copies to, and that
#                        name belongs to the site that runs the lane, not in a
#                        report. Unset, it changes nothing.

# shellcheck disable=SC2016  # the python text names shell variables for the pasted shell to expand, not this one
offsite_block() {
  python3 -c '
import sys
ca = len(sys.argv) > 1 and sys.argv[1] == "ca"
L = sys.stdin.read().rstrip("\n").split("\n")
if "  --dry-run" not in L:
    sys.exit("offsite_block: the block has no --dry-run line to add a destination before")
i = L.index("  --dry-run")
if i == 0 or not L[i - 1].endswith("\\"):
    sys.exit("offsite_block: the line before --dry-run does not continue onto it")
flags = "  --offsite-git \"$OFFSITE_GIT_URL\" --offsite-git-credentials \"$OFFSITE_GIT_CREDENTIALS\""
if ca:
    flags += " --offsite-git-ca \"$OFFSITE_GIT_CA\""
L.insert(i, flags + " \\")
print("\n".join(L))
' "${1:-}"
}

offsite_scrub() {
  if [ -z "${TOCKMOX_P09_OFFSITE_SCRUB:-}" ]; then cat; return 0; fi
  python3 -c '
import os, re, sys
host = os.environ["TOCKMOX_P09_OFFSITE_SCRUB"]
sys.stdout.write(re.sub(re.escape(host), "<off-site host>", sys.stdin.read(), flags=re.I))
'
}

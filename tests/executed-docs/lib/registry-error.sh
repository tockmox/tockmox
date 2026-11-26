#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Tell a registry refusal from a documentation change.
#
# A path that runs `helm show chart oci://...` and then parses a version out of the output can
# fail to find one for two very different reasons. The page may have changed (the command no
# longer prints what the path expects), or the registry may have refused the request: Docker
# Hub answers an anonymous manifest GET with a 429 once the pull allowance for the address is
# spent, and helm then prints an `Error:` line and nothing on stdout. The first is a finding
# about the page. The second says nothing about the page at all, so reading it as "section gone"
# sends a reader to edit a correct doc. It is INFRA_ERROR (lib/assert.sh's outcome model).
#
# Sourced, not executed:  . "${HERE}/../lib/registry-error.sh"

# registry_error_line OUTPUT
#   Prints the first line of OUTPUT that is a registry or helm error, trimmed to one bounded line
#   with control characters removed, and returns 0. Returns 1 and prints nothing when there is
#   none. Call it only after the version failed to parse: a run that printed a version is not
#   judged by a stray warning.
registry_error_line() {
  local line
  line="$(printf '%s\n' "${1:-}" \
    | grep -i -m1 -E 'toomanyrequests|rate limit|response status code (429|5[0-9][0-9])|^Error:')" || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | tr -d '\000-\010\013-\037' | cut -c1-300
}

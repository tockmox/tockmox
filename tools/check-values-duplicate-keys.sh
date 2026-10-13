#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fails if any chart's values.yaml declares the same top-level key twice.
#
# WHY THIS EXISTS, and it is a first-hand account rather than a hypothetical.
# On 2026-08-15 a change appended an `open-webui:` block to a values file that
# already had one. YAML duplicate-key resolution keeps the LAST occurrence and
# silently discards the earlier one, so the entire original block vanished:
# Pipelines came back on, and the settings that keep the console off a
# third-party API went away.
#
# Everything downstream passed. `helm lint` reported 9 of 9 charts clean.
# `helm template` rendered without error. The diff looked like an addition,
# because it was one. The fault surfaced only when the rendered PVC count was
# counted and had dropped from ten to three.
#
# That is the whole argument for this check: the failure is invisible to every
# tool in the pipeline and obvious to five lines of grep.
#
# SCOPE, deliberately narrow. Top-level keys only, in `charts/*/values.yaml`.
# Nested duplicates are rarer, harder to detect with text tools, and would need
# a real YAML parse with a duplicate-key-detecting loader. If that becomes
# worth doing, do it properly rather than extending the regex.
set -euo pipefail

rc=0
shopt -s nullglob

for f in charts/*/values.yaml; do
  # Top-level keys are the ones with no leading whitespace. Comments and list
  # items cannot match because the pattern is anchored and requires a colon.
  dups=$(grep -oE '^[A-Za-z_][A-Za-z0-9_.-]*:' "$f" | sort | uniq -d || true)
  if [ -n "$dups" ]; then
    rc=1
    echo "FAIL  $f"
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      echo "        duplicate top-level key: ${k%:}"
      grep -nE "^${k%:}:" "$f" | sed 's/^/          line /'
    done <<< "$dups"
    echo "        YAML keeps the LAST one and silently drops the others."
  else
    printf '  ok    %s\n' "$f"
  fi
done

if [ "$rc" -ne 0 ]; then
  echo
  echo "Duplicate top-level keys found. Merge the blocks rather than appending"
  echo "a second one; the earlier block is being discarded."
fi

exit "$rc"

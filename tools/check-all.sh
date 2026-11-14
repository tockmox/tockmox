#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# EVERY STATIC GATE, IN ONE COMMAND.
#
# CONTRIBUTING.md tells you your pull request must pass CI. Until 2026-09-03
# there was no way to find out except by opening one, and CONTRIBUTING listed
# only a subset of the checks. An outside review predicted the resulting issue
# almost word for word: "I ran the commands in CONTRIBUTING and CI still failed
# on an undocumented gate."
#
# So this runs what `ci.yaml` runs, minus the parts that genuinely need
# something a laptop does not have ... plus, for now, eight gates that run here
# and are not yet wired into ci.yaml: the two CNPG policy gates
# (check-cnpg-netpol, check-cnpg-operator-reach), check-ingress-tls,
# check-pod-security, check-dashboard-panels, check-litellm-hooks, the two check-harness-context.sh
# runs (also run by executed-docs.yaml's hermetic selftest job) and the two check-docs-offline.sh
# runs (the second skips without the pinned MkDocs toolchain, so a run
# with no docs venv reports it as skipped), and the 0.7.1 wave's four gates with
# their selftests: check-identity-seams, check-platform-seams,
# check-immutable-fields and check-action-pins, then wave 2's
# check-capability-monitors, check-cloud-egress and check-notify-and-drill
# (2026-10-03; the count of
# check-all-only gates above is no longer eight, and this list is not
# exhaustive ... the run_gate lines below are). Adding a CI gate is its own
# multi-file change (it moves a count that four pages state and doc-claims.txt
# pins), which is why
# they wait here rather than land half-registered.
#
# WHAT IT DOES NOT COVER, stated rather than skipped silently:
#
#   - `gitleaks (full history)` needs the gitleaks binary and a full clone.
#   - `kubeconform rendered output` runs only with kubeconform on PATH
#     (tools/check-kubeconform.sh; skipped, never passed, without it).
#   - `every commit carries a DCO sign-off` is checked against the commits a
#     pull request adds, which a working tree does not know. Run
#     `git log --format='%B' origin/main..HEAD | grep -c '^Signed-off-by:'`
#     yourself and compare it to your commit count.
#   - `render every layer at the previous release tag and at this candidate`
#     needs both refs and is a release-time check.
#   - the executed-documentation paths need a live cluster. That is the whole
#     point of them; see tests/executed-docs/README.md.
#
# WHY EACH GATE ASSERTS ITS OWN DEPENDENCIES FIRST. On 2026-09-03,
# check-capabilities.sh was run with no helm on PATH and reported ELEVEN
# specific capability-framework defects that did not exist ... its render helper
# swallowed the missing binary, so every capability looked like a switch that
# changed nothing. A gate that invents findings when its tooling is absent is
# worse than one that refuses to run. This script therefore checks for helm
# once, up front, and REFUSES rather than producing a plausible wrong answer.

set -uo pipefail
cd "$(dirname "$0")/.."

# WHICH GATES, AND WHERE. With no arguments every gate runs, as it always has.
#
#   --changed-from REF   run only the gates whose declared inputs (tools/gate-inputs.yaml) changed
#                        since REF, plus every gate that declares none. A change to the runner, the
#                        planner, the declarations or the toolchain runs everything.
#   --shard I/N          run only this shard's share, split by measured seconds (tools/gate-weights.tsv);
#                        N shards' results together are one unsharded run.
#   --list               print the registered gates (ordinal, key, serial flag, name) and run nothing.
#   --strict             a skip is not green: a run with no failure that skipped a gate, or left one
#                        unselected, exits 2 (BLOCKED) instead of 0. A failure still exits 1. This is
#                        the release mode (RELEASING.md: "A SKIP is not green; exit code 2 is BLOCKED").
#                        CHECK_ALL_STRICT=1 does the same.
#
# Each run writes one row per gate to build/check-all-results.tsv (CHECK_ALL_RESULTS to move it):
# ordinal, key, status (pass, fail, skip, timeout, unselected, othershard), exit code, seconds, name.
# Beside it, the same name with .meta.json for .tsv, it writes what the rows were run on: the commit
# (head_sha), whether the checkout was clean when the run started, the mode (strict, changed_from,
# shard), the counts and the exit status. tools/train-morning.sh reads both as check-all evidence.
# tools/gate-plan.py holds the selection and shard rules and their selftest.
LIST_ONLY=0
STRICT="${CHECK_ALL_STRICT:-0}"
case "$STRICT" in 1|true|yes) STRICT=1 ;; *) STRICT=0 ;; esac
CHANGED_FROM="${CHECK_ALL_CHANGED_FROM:-}"
SHARD="${CHECK_ALL_SHARD:-}"
RESULTS="${CHECK_ALL_RESULTS:-build/check-all-results.tsv}"
while [ $# -gt 0 ]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --strict) STRICT=1 ;;
    --changed-from) [ $# -ge 2 ] || { echo "check-all.sh: --changed-from needs a git ref" >&2; exit 1; }
                    CHANGED_FROM="$2"; shift ;;
    --shard) [ $# -ge 2 ] || { echo "check-all.sh: --shard needs I/N" >&2; exit 1; }
             SHARD="$2"; shift ;;
    -h|--help) sed -n '/^# WHICH GATES/,/^LIST_ONLY=/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "check-all.sh: unknown argument: $1 (try --help)" >&2; exit 1 ;;
  esac
  shift
done

pass=0; fail=0; skipped=0; unselected=0; othershard=0; skipped_names=""
failed_names=""; unselected_names=""
gate_ord=0; GATE_SERIAL=0

have() { command -v "$1" >/dev/null 2>&1; }

# A gate's key names it in tools/gate-inputs.yaml and tools/gate-weights.tsv: the script and its
# arguments (`tools/check-x.sh --selftest`), or `inline:<name>` for a gate written inline here.
gate_key() {
  local name="$1"; shift
  case "${1:-}" in bash|python3|sh) shift ;; esac
  if [ "${1:-}" = "-c" ]; then
    printf 'inline:%s' "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-60 | sed 's/-$//')"
  else
    printf '%s' "$*"
  fi
}

# GATES RUN IN PARALLEL (Jeff 2026-10-11: "let's absolutely run the gates in parallel").
# One run was about 45 minutes on a 2-CPU runner, gate after gate, while every gate is an
# independent process that renders the charts into its own mktemp directory. Now up to
# CHECK_ALL_JOBS gates run at once (default: the CPU count), each writing its output to its own
# file, and the report is printed in the SAME ORDER and with the SAME counts as a serial run, with
# each gate's wall time beside its name and the slowest listed at the end.
#
#   CHECK_ALL_JOBS=1   the old behaviour: one gate at a time, output streamed as it runs (and kept, to read its SKIPPED: line).
#
# Gates that read what another gate writes, or build into a shared directory, run alone behind a
# barrier (`serial_gate`): render-counts writes build/render-counts.tsv that doc-claims reads, and
# the docs gates build and read the one site directory. Everything else is independent by
# construction (every gate's scratch is its own mktemp), and the run asserts the tree it started
# from is the tree it ends with, so a gate that writes into the checkout is caught rather than
# raced.
cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2
}
JOBS="${CHECK_ALL_JOBS:-$(cpu_count)}"
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac

# A GATE THAT NEVER RETURNS IS NAMED, NOT SWALLOWED (2026-10-27). In parallel mode a gate's output is
# held until the end, so one gate that loops forever used to hold the whole run until something
# outside killed it, and the report named nothing. Now each gate runs under a time limit,
# CHECK_ALL_GATE_TIMEOUT seconds (default 1200; 0 = no limit). A gate past it is stopped with
# everything it started (its own process group, so a python child spinning under a bash gate goes
# too) and counted as a failure named "TIMEOUT after N s". Serial mode (CHECK_ALL_JOBS=1) streams
# each gate's name before it runs, so a hang there is already named, and it is left without the time
# limit's wrapper so a gate keeps the terminal for its input (its output is also kept, to read its SKIPPED: line). A caller with its own budget for the whole run (a CI job's timeout, a QA
# harness) should give it more than this limit, so a hang ends here, with a name, first.
GATE_TIMEOUT="${CHECK_ALL_GATE_TIMEOUT:-1200}"
case "$GATE_TIMEOUT" in ''|*[!0-9]*) GATE_TIMEOUT=1200 ;; esac
GATE_TIMEOUT_PY='
import os, signal, subprocess, sys
secs = int(sys.argv[1])
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
def stop(*_):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            return
        try:
            p.wait(timeout=5)
            return
        except subprocess.TimeoutExpired:
            pass
def on_signal(signum, _):
    stop()
    sys.exit(128 + signum)
signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)
try:
    rc = p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    stop()
    print("  TIMEOUT: still running after %d s; the gate and everything it started were stopped" % secs, flush=True)
    sys.exit(124)
sys.exit(128 - rc if rc < 0 else rc)
'
SLOTS="$(mktemp -d)"
trap 'rm -rf "$SLOTS"' EXIT
nslot=0
tree_status() {
  # Tracked and untracked files outside build/ and the vendored subcharts that differ from HEAD.
  git status --porcelain --untracked-files=all 2>/dev/null | grep -v -e ' build/' -e '/charts/[^/]*\.tgz$' -e '__pycache__' | sort
}
tree_fingerprint() {
  # The same files, contents included.
  tree_status
  git diff 2>/dev/null | cksum
}

# A GATE IS SKIPPED ONLY WHEN IT SAYS SO. Exit 2 is the repository's "could not run" (see the long note at
# the top of check-blueprint-discovery.sh): a gate that cannot run because a substrate is absent is a
# different report from a gate that ran and found a defect, and collapsing the two teaches people to skim
# past red in this directory. But exit 2 alone is not that statement. A bash syntax error, a grep on a file
# that is not there and an argparse usage error all exit 2 as well, and a run that booked those as skipped
# ended "All runnable static gates passed" over a gate that had never run. So:
#
#   exit 0                                           pass (a SKIPPED: line in a passing gate's output is ignored)
#   exit 2 AND a line starting "SKIPPED: <reason>"   skip
#   exit 2 without that line                         FAIL
#   anything else                                    FAIL
#
# The gate's captured output is what is read, standard error included. The reason is printed in the run's
# summary beside the gate's name, so a skip is never only a count.
skip_reason_of() { # LOGFILE ... the first "SKIPPED: reason" line's reason, empty when there is none
  [ -r "$1" ] || return 0
  sed -n 's/^SKIPPED: \([^[:space:]].*\)$/\1/p' "$1" | head -n 1
}
gate_status() { # RC LOGFILE ... pass, skip, timeout or fail
  case "$1" in
    0) echo pass ;;
    2) if [ -n "$(skip_reason_of "$2")" ]; then echo skip; else echo fail; fi ;;
    124) [ "$GATE_TIMEOUT" -gt 0 ] && echo timeout || echo fail ;;
    *) echo fail ;;
  esac
}
tally() { # NAME RC LOGFILE
  case "$(gate_status "$2" "$3")" in
    pass) pass=$((pass + 1)) ;;
    skip) skipped=$((skipped + 1))
          skipped_names="${skipped_names}
  - ${1}: $(skip_reason_of "$3")" ;;
    *) fail=$((fail + 1))
       if [ "$2" = 2 ]; then
         failed_names="${failed_names}
  - ${1} (exited 2 without a 'SKIPPED: <reason>' line, so it did not skip: it failed)"
       else
         failed_names="${failed_names}
  - ${1}"
       fi ;;
  esac
}

# One results row: ordinal, key, status, exit code, seconds, name.
result_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$SLOTS/results"
}

# The plan's decision for this gate: run, unselected or othershard. No plan: run.
gate_decision() {
  [ -n "$PLAN" ] || { echo run; return 0; }
  if [ "${PLAN_KEY[$1]:-}" != "$2" ]; then
    echo "check-all.sh: gate $1 is '$2' now and '${PLAN_KEY[$1]:-<none>}' in the plan; the two passes disagree" >&2
    echo run; return 0
  fi
  echo "${PLAN_DEC[$1]}"
}

run_gate() {
  local name="$1"; shift
  local rc=0 key serial="$GATE_SERIAL"
  gate_ord=$((gate_ord + 1))
  key="$(gate_key "$name" "$@")"
  if [ "$LIST_ONLY" = 1 ]; then
    printf '%s\t%s\t%s\t%s\n' "$gate_ord" "$key" "$serial" "$name"
    return 0
  fi
  case "$(gate_decision "$gate_ord" "$key")" in
    unselected)
      unselected=$((unselected + 1)); unselected_names="${unselected_names}
  - ${name}"
      result_row "$gate_ord" "$key" unselected - - "$name"
      return 0 ;;
    othershard)
      othershard=$((othershard + 1))
      result_row "$gate_ord" "$key" othershard - - "$name"
      return 0 ;;
  esac
  if [ "$JOBS" -le 1 ]; then
    printf '\n=== %s ===\n' "$name"
    local t0; t0=$(date +%s)
    # Streamed as before, and kept, because whether a gate skipped is read from what it printed.
    "$@" 2>&1 | tee "$SLOTS/serial.log"
    rc="${PIPESTATUS[0]}"
    tally "$name" "$rc" "$SLOTS/serial.log"
    result_row "$gate_ord" "$key" "$(gate_status "$rc" "$SLOTS/serial.log")" "$rc" "$(( $(date +%s) - t0 ))" "$name"
    return 0
  fi
  nslot=$((nslot + 1))
  local slot; slot="$SLOTS/$(printf '%04d' "$nslot")"
  printf '%s\n' "$name" > "$slot.name"
  printf '%s\t%s\n' "$gate_ord" "$key" > "$slot.key"
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.2; done
  (
    t0=$(date +%s)
    if [ "$GATE_TIMEOUT" -gt 0 ]; then
      python3 -c "$GATE_TIMEOUT_PY" "$GATE_TIMEOUT" "$@" > "$slot.log" 2>&1 < /dev/null
    else
      "$@" > "$slot.log" 2>&1 < /dev/null
    fi
    echo "$?" > "$slot.rc.tmp"
    echo $(( $(date +%s) - t0 )) > "$slot.secs"
    mv "$slot.rc.tmp" "$slot.rc"
  ) &
}

barrier() {
  [ "$JOBS" -le 1 ] || wait
}

# A gate that must not overlap any other (see the note at the top). The planner keeps every
# serial gate on one shard, so a gate that reads what another serial gate wrote still finds it.
serial_gate() {
  barrier
  GATE_SERIAL=1
  run_gate "$@"
  GATE_SERIAL=0
  barrier
}

skip_gate() {
  local key; key="skip:$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-60 | sed 's/-$//')"
  gate_ord=$((gate_ord + 1))
  if [ "$LIST_ONLY" = 1 ]; then
    printf '%s\t%s\t0\t%s\n' "$gate_ord" "$key" "$1"
    return 0
  fi
  case "$(gate_decision "$gate_ord" "$key")" in
    unselected)
      unselected=$((unselected + 1)); unselected_names="${unselected_names}
  - ${1}"
      result_row "$gate_ord" "$key" unselected - - "$1"
      return 0 ;;
    othershard)
      result_row "$gate_ord" "$key" othershard - - "$1"
      othershard=$((othershard + 1))
      return 0 ;;
  esac
  if [ "$JOBS" -le 1 ]; then
    printf '\n=== %s ===\nSKIPPED: %s\n' "$1" "$2"
    skipped_names="${skipped_names}
  - ${1}: ${2}"
    skipped=$((skipped + 1))
    result_row "$gate_ord" "$key" skip 2 0 "$1"
    return 0
  fi
  nslot=$((nslot + 1))
  local slot; slot="$SLOTS/$(printf '%04d' "$nslot")"
  printf '%s\n' "$1" > "$slot.name"
  printf '%s\t%s\n' "$gate_ord" "$key" > "$slot.key"
  printf 'SKIPPED: %s\n' "$2" > "$slot.log"
  echo 0 > "$slot.secs"
  echo 2 > "$slot.rc"
}

# WHAT THE ROWS WERE RUN ON, for the .meta.json beside the results. A results file is evidence for
# a commit only when it says which one, and only when the checkout matched it: a run over uncommitted
# edits describes no commit at all.
START_HEAD="$(git --no-optional-locks rev-parse HEAD 2>/dev/null || true)"
START_DIRTY="$(tree_status | wc -l | tr -d ' ')"

PLAN=""
if [ "$LIST_ONLY" = 0 ]; then
echo "Tockmox static gates, run locally."
echo "Repository: $(pwd)"
[ "$STRICT" = 0 ] || echo "Mode: strict. A skipped or unselected gate is not green: the run exits 2 (BLOCKED)."

# A CLONE, NOT AN UNPACKED ARCHIVE. Several gates judge `git ls-files` (what ships), two compare against the
# previous release tag, and the tree-unchanged assertion at the end reads `git status`. Outside a git checkout
# those either skip or, worse, pass having read nothing, so this refuses rather than report a partial suite as
# a run. A change made in an archive also has no base blob ids to apply against a moved main.
if ! git --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo
  echo "NOT A GIT CHECKOUT: $(pwd)"
  echo "check-all.sh needs a clone: git clone https://github.com/tockmox/tockmox.git"
  exit 1
fi

# ---------------------------------------------------------------- dependencies
missing=""
have helm || missing="${missing} helm"
have python3 || missing="${missing} python3"
# Many gates under tools/ import yaml. Without PyYAML they die mid-suite
# with a traceback that reads like a broken gate, so ask up front.
if have python3 && ! python3 -c 'import yaml' >/dev/null 2>&1; then
  missing="${missing} python3-yaml"
fi
have jq || missing="${missing} jq"

if [ -n "$missing" ]; then
  echo
  echo "MISSING TOOLS:${missing}"
  echo
  echo "This script refuses to run a partial suite, because several gates cannot"
  echo "tell the difference between 'the tree is wrong' and 'the tool is absent',"
  echo "and they report the first when they mean the second."
  echo
  echo "  helm     the version mise.toml pins: tools/dev-env.sh installs it, or https://helm.sh/docs/intro/install/"
  echo "  jq       your package manager"
  echo "  python3  the minor version mise.toml pins, or newer"
  echo "  python3-yaml  python3 -m pip install pyyaml, or your package manager's python3-yaml"
  exit 1
fi

# THE TOOLCHAIN IS CI'S, OR NOTHING RUNS. A render gate passed in an environment with Helm 3.16 and failed on
# a Mac and in CI with Helm 4.3.1, and nothing in the green run said it had used another Helm. mise.toml is the
# one place the versions live; tools/toolchain.sh holds the tools on PATH to it, and a mismatch stops the run
# here, before a gate result that would not predict CI.
printf '\n'
bash tools/toolchain.sh --check || {
  echo
  echo "check-all.sh refuses to run with a toolchain that is not the pinned one (above)."
  exit 1
}

# Subchart dependencies are vendored, so no `helm dep update` is needed. This
# only rebuilds Chart.lock consistency if something is genuinely absent.
if [ -x tools/helm-deps.sh ]; then
  printf '\n=== helm dependencies ===\n'
  bash tools/helm-deps.sh || {
    echo "helm-deps failed; every render gate below would fail for that reason."
    exit 1
  }
fi


# ------------------------------------------------------------- the plan
# Only when asked: the gates are listed by a second pass of this script that runs nothing, the
# planner decides, and each run_gate below asks the plan before it runs. A changed-path list that
# cannot be made (an unknown ref, a shallow clone) means a full run, said here, never a guess.
if [ -n "$CHANGED_FROM" ] || [ -n "$SHARD" ]; then
  plan_args=(plan --list "$SLOTS/list.tsv" --out "$SLOTS/plan.tsv")
  CHECK_ALL_CHANGED_FROM="" CHECK_ALL_SHARD="" bash tools/check-all.sh --list > "$SLOTS/list.tsv" \
    || { echo "check-all.sh: could not list the gates"; exit 1; }
  if [ -n "$CHANGED_FROM" ]; then
    if git --no-optional-locks rev-parse -q --verify "${CHANGED_FROM}^{commit}" >/dev/null 2>&1 \
       && { git --no-optional-locks diff --name-only "$CHANGED_FROM" -- && git --no-optional-locks ls-files --others --exclude-standard; } > "$SLOTS/changed.txt" 2>/dev/null; then
      plan_args+=(--changed "$SLOTS/changed.txt")
    else
      printf '\nNo changed-path list from %s (unknown ref or no history); every gate runs.\n' "$CHANGED_FROM"
    fi
  fi
  [ -n "$SHARD" ] && plan_args+=(--shard "$SHARD")
  printf '\n=== which gates run ===\n'
  python3 tools/gate-plan.py "${plan_args[@]}" || { echo "check-all.sh: the gate planner failed; nothing ran"; exit 1; }
  PLAN="$SLOTS/plan.tsv"
  PLAN_KEY=(); PLAN_DEC=()
  while IFS=$'\t' read -r p_ord p_key p_dec _; do
    PLAN_KEY[p_ord]="$p_key"; PLAN_DEC[p_ord]="$p_dec"
  done < "$PLAN"
fi
fi

# ---------------------------------------------------------------------- gates
[ "$LIST_ONLY" = 1 ] || TREE_BEFORE="$(tree_fingerprint)"
[ "$JOBS" -le 1 ] || [ "$LIST_ONLY" = 1 ] || printf '\nRunning the gates %s at a time (CHECK_ALL_JOBS=1 for one at a time).\n' "$JOBS"
run_gate "every copy of a tool pin says what mise.toml says" bash tools/toolchain.sh --drift
run_gate "the toolchain checks go red on a planted mismatch" bash tools/toolchain.sh --selftest
run_gate "every tool is executable" bash -c '
  bad=0
  for f in tools/*.sh; do
    [ -x "$f" ] || { echo "  NOT EXECUTABLE: $f"; bad=1; }
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

# The offline path of helm-deps.sh (D5): a tree that carries every
# upstream subchart never contacts a repository, and anything less goes online.
run_gate "helm-deps goes offline only when every upstream subchart is vendored at its Chart.lock version" \
  bash tools/helm-deps.sh --selftest

# THE TWO GUARDS THAT EXIST BECAUSE SOMETHING SHIPPED, added 2026-09-16. Both
# run here rather than by hand, because both classes travelled all the way into
# a cluster with nothing looking, and a self-test nobody invokes is the same as
# no self-test. Neither needs helm, promtool, kubectl or a cluster, so they cost
# nothing and can never be the reason this script skips.
run_gate "the image extractor handles every quoting form" \
  bash tools/lib/extract-images.sh --selftest
run_gate "mint-secrets refuses a value with a control character" \
  bash tools/mint-secrets.sh --selftest

# A TOOL THAT CANNOT RUN IS NOT A FINDING, added 2026-10-16. Four gates
# partition on a missing helm or promtool; each now also treats one that is on
# PATH and cannot execute as missing, and render-counts no longer leaves a
# counts file behind a failed render. Fixture tools on a hermetic PATH, so none
# of these needs a working helm either.
run_gate "the tool probe tells a tool that cannot run from one that runs" \
  bash tools/lib/tool-runs.sh --selftest
run_gate "render-counts leaves no counts file after a failed render" \
  bash tools/render-counts.sh --selftest
run_gate "check-capabilities skips rather than accuses with a helm that cannot run" \
  bash tools/check-capabilities.sh --selftest
run_gate "check-alert-rules skips rather than accuses with a helm or promtool that cannot run" \
  bash tools/check-alert-rules.sh --selftest
run_gate "check-doc-claims skips rather than accuses on a missing tool or a stale counts file" \
  bash tools/check-doc-claims.sh --selftest

# Both passes, exactly as ci.yaml runs them. A bare `helm lint` with no values
# fails EVERY chart on `global.internalDomain` being empty, which is the schema
# working correctly and says nothing whatever about the tree. This script did
# exactly that on its first run and reported nine charts broken ... the same
# defect it was written to prevent, one file later. The all-on overlay is the
# second pass because paths the defaults never render (backups, hardware
# telemetry, the consoles' ingresses) are otherwise linted by nobody, which hid
# a real lint-breaking defect for weeks.
run_gate "helm lint (all layer charts, both value sets)" bash -c '
  bad=0
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    [ -f "$c/Chart.yaml" ] || continue
    helm lint "$c" -f ci/values.yaml >/dev/null 2>&1 \
      || { echo "  LINT FAILED (defaults): $c"; bad=1; }
    helm lint "$c" -f ci/values.yaml -f ci/values-all-on.yaml >/dev/null 2>&1 \
      || { echo "  LINT FAILED (all-on): $c"; bad=1; }
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

# ci.yaml's "every layer renders against the smallest real site" step. It was
# missing here until 2026-10-06, which let a newly added required key pass
# this script and fail CI (and render-diff, which renders the same file).
run_gate "every layer renders against ci/values-site-minimal.yaml" bash -c '
  bad=0
  for c in charts/tockmox-*; do
    [ "$c" = "charts/tockmox-common" ] && continue
    if ! out=$(helm template t "$c" -f ci/values-site-minimal.yaml 2>&1); then
      echo "  RENDER FAILED: $c"; printf "%s\n" "$out" | head -3 | sed "s/^/    /"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] && echo "  ok"
  exit "$bad"'

run_gate "no duplicate top-level keys in values files" bash tools/check-values-duplicate-keys.sh
run_gate "every capability is a switch that does something" bash tools/check-capabilities.sh
run_gate "no NetworkPolicy guards an empty namespace" bash tools/check-no-ghost-policies.sh
run_gate "every NetworkPolicy selector can actually match" bash tools/check-netpol-selectors.sh
run_gate "every NetworkPolicy selects a rendered pod" bash tools/check-policy-selects.sh
run_gate "the policy-selects gate can fail" bash tools/check-policy-selects.sh --selftest
run_gate "Knowledge mode renders as designed and refuses what it must" bash tests/knowledge/render.sh
run_gate "per-tool egress renders as designed and refuses what it must" bash tests/agent-egress/render.sh
run_gate "a content-logging observability callback is refused" bash tests/content-logging/render.sh
run_gate "every aggregated ClusterRole we ship is allowlisted" bash tools/check-rbac-aggregation-allowlist.sh
run_gate "the alert rules we author are tested" bash tools/check-alert-rules.sh
run_gate "every alert we author has a kured reboot-gate decision, and the printed regexp is what the decisions imply" bash tools/check-kured-gate.sh
run_gate "the kured-gate check goes red on an unclassified alert, a stale line, a renamed upstream alert and a drifted regexp" bash tools/check-kured-gate.sh --selftest
run_gate "Loki is one replica on the filesystem by default, a second replica on the filesystem is refused, and the documented HA values render three on an object store" bash tools/check-loki-ha.sh
run_gate "the Loki HA check goes red on one replica, a filesystem schema, a filesystem compactor, replication factor 1 and filesystem storage" bash tools/check-loki-ha.sh --selftest
run_gate "opt-in CoreDNS HA: the stock render writes no HPA or PDB in kube-system, the switch adds exactly those two, a floor under 2 is refused by name" bash tools/check-coredns-ha.sh
run_gate "the CoreDNS HA gate goes red on every mutation" bash tools/check-coredns-ha.sh --selftest
run_gate "every CNPG database has an ingress NetworkPolicy" bash tools/check-cnpg-netpol.sh
run_gate "every CNPG database is reachable by its operator on :8000" bash tools/check-cnpg-operator-reach.sh
run_gate "storage policy holds on the rendered claims" bash tools/check-storage-policy.sh
run_gate "no namespace enforces a Pod Security level its pods fail" bash tools/check-pod-security.sh
run_gate "every rendered Ingress terminates TLS" bash tools/check-ingress-tls.sh
run_gate "every shipped table panel that hides columns also orders them" bash tools/check-dashboard-panels.sh
run_gate "the overview board is what its generator writes" python3 tools/gen-dashboard-overview.py --check
run_gate "the status board is what its generator writes from the UI's panels" python3 tools/gen-dashboard-status.py --check
run_gate "the UI holds no write credential, and tockmox-actions is narrow, bounded by admission policy and reachable from the UI only" python3 tools/check-actions.py
run_gate "the actions gate goes red on every planted grant, gap and leak" python3 tools/check-actions.py --selftest
run_gate "the Platform Management page lists the catalog the UI ships" python3 tools/gen-platform-catalog-doc.py --check
run_gate "every OIDC console gets a trust bundle" bash tools/check-trust-wiring.sh
run_gate "a product bump of Open WebUI or LiteLLM reaches a site with no site edit" bash tools/check-site-follows-product.sh
run_gate "the site-follows-product gate goes red on every mutation" bash tools/check-site-follows-product.sh --selftest
run_gate "site LiteLLM hooks load through values alone" bash tools/check-litellm-hooks.sh
# No known-bad LiteLLM digest or 1.107.0 tag (the incident) is named in images.txt, the SBOM, a chart or any
# other file outside the docs; the list is tools/litellm-bad-digests.txt. Not in ci.yaml yet, for the reason at
# the top of this file.
run_gate "no known-bad LiteLLM image digest or 1.107.0 tag appears in images.txt or anywhere else a LiteLLM image can be named" bash tools/check-litellm-compromise.sh
run_gate "the LiteLLM-compromise gate goes red on the index digest, each platform manifest, the published 12-hex prefixes, the exact bad tag and a bad list, and passes the next release" bash tools/check-litellm-compromise.sh --selftest
run_gate "inference-node routes match the UI and the eval gateway is fenced" bash tools/check-inference-nodes.sh
run_gate "the production health watch renders with no token, the right image and only the egress it needs" bash tools/check-health-watch.sh
run_gate "the eval scheduler and the health watch are admitted to Prometheus by tockmox-policy (labels joined across charts)" bash tools/check-model-jobs-reach.sh
# The AI-node toolkit (ai-node/): lint, unit tests and the converger wrapper's tests. Not in ci.yaml yet,
# for the reason the posture-probe note below gives. The Linux simulation of the whole playbook changes the
# host (empty directories, tmpfs and overlays in a private mount namespace) and takes about five minutes,
# so it runs only when TOCKMOX_AI_NODE_E2E=1.
run_gate "the AI-node toolkit lints, and its unit and converger tests pass" bash tools/check-ai-node.sh
run_gate "the AI-node toolkit's own lints go red on a bash 4 feature, a GNU option and a printed key" bash tools/check-ai-node.sh --selftest
if [ "${TOCKMOX_AI_NODE_E2E:-0}" = 1 ]; then
  run_gate "the AI-node playbook converges twice against the macOS shims (Linux simulation)" bash tools/check-ai-node.sh --e2e
else
  skip_gate "AI-node playbook simulation" "set TOCKMOX_AI_NODE_E2E=1 (needs root and Linux; changes the host)"
fi
# The posture-probe add-on. Not in ci.yaml yet: wiring a CI
# gate moves the counts doc-claims.txt pins, and that is its own change.
run_gate "the posture-probe add-on stays observe-only: read-only role, confined policy, versioned report" bash tools/check-posture-probe.sh
run_gate "the posture-probe gate goes red on a write verb, a widened read, a leaked output and a broken contract" bash tools/check-posture-probe.sh --selftest
# The first-party add-on manifest: the manifest, the settings schema, no code in the admin origin
# and the operations contract, held against each add-on's render. Not in ci.yaml yet, for the same reason
# as the posture-probe gate above; the add-on's values keys ARE in ci.yaml, through check-values-tiers.
run_gate "every add-on keeps its manifest: settings schema, no code in the admin origin, operations contract" bash tools/check-addon-manifest.sh
run_gate "the add-on manifest gate goes red on a missing manifest, browser code, a route, a write verb and an undeclared claim" bash tools/check-addon-manifest.sh --selftest
run_gate "the upgrade-wedging shapes from the 0.7.0 lab pass stay fixed" bash tools/check-upgrade-safety.sh
run_gate "the upgrade-safety gate goes red on a migrations Job that is not a Sync hook, a pre-upgrade backup that does not wait, or a drift from upstream" bash tools/check-upgrade-safety.sh --selftest
# A pipe into `grep -q` under pipefail fails at random: grep exits at the first
# match and the writer dies of SIGPIPE (141). Over a hundred of these made this
# script go red on pushes whose PR run had passed.
run_gate "no pipe into grep -q under pipefail (a match must not read as a SIGPIPE)" python3 tools/check-pipe-grep-q.py
run_gate "the grep -q pipe gate goes red on every shape it names, and green on the fixed form" python3 tools/check-pipe-grep-q.py --selftest
# BSD grep reads \| in a basic pattern as two literal characters, so `grep -q 'a\|b'` can never match on a Mac:
# a gate written that way is green there whatever the tree holds, and a documented command prints the wrong set.
run_gate "no GNU-only alternation in a basic grep pattern (BSD grep reads \\| literally)" python3 tools/check-grep-portability.py
run_gate "the grep-portability gate goes red on each shape, and green on the -E form" python3 tools/check-grep-portability.py --selftest
run_gate "no bare kubectl or helm in the executed-docs harness" bash tools/check-harness-context.sh
run_gate "the harness-context gate goes red on a bare call" bash tools/check-harness-context.sh --selftest
run_gate "the six no-cluster documentation pages execute: every bash block runs and its output is asserted (also docs-no-cluster.yaml)" bash tests/executed-docs/pages-no-cluster.sh
run_gate "the no-cluster pages job goes red on a broken command, an unclassified block, a vanished section, a renamed placeholder and a wrong tag" bash tests/executed-docs/pages-no-cluster.sh --selftest
run_gate "a lanCIDR containing the clusterCIDR is refused when nodeOriginSources is set" bash tools/check-lan-cidr-overlap.sh
run_gate "garage.blockSize renders block_size only when set, above the tables" bash tools/check-garage-block-size.sh
run_gate "Garage key rotation: the old key is deleted before the new Secret, no orphan keeps a grant, every copy follows, under the Job's own Roles" bash tests/garage-bootstrap/key-rotation.sh
run_gate "the garage-key-rotation gate goes red on every mutation" bash tests/garage-bootstrap/key-rotation.sh --selftest
run_gate "SSO blueprints are parseable YAML" bash tools/check-blueprint-discovery.sh
run_gate "every SSO application is bound to a role group" bash tools/check-sso-bindings.sh
run_gate "forward-auth consoles: provider, Middleware, callback and route name each other across layers" bash tools/check-forward-auth.sh
run_gate "the forward-auth gate goes red on every mutation" bash tools/check-forward-auth.sh --selftest
run_gate "identity and AI seams: host, sub_mode, merge-by-email, DB recovery and backup default, Grafana email path, admin-users Job, mint --only" bash tools/check-identity-seams.sh
run_gate "the identity-seams gate goes red on every assertion" bash tools/check-identity-seams.sh --selftest
run_gate "platform seams: namespace labels, probe hosts, dashboard keys, CNPG PodMonitor, etcd, Retain" bash tools/check-platform-seams.sh
run_gate "the platform-seams gate goes red on every assertion" bash tools/check-platform-seams.sh --selftest
# The namespace guard (apps.namespace_guard, off by default). Evaluates its exemption
# expression with cel-python against every ServiceAccount the layers ship; skips (exit 2)
# without cel-python, which check-all.yaml installs.
run_gate "the namespace guard admits every identity the product runs as and refuses the rest" bash tools/check-namespace-guard.sh
run_gate "the namespace-guard gate goes red on each planted exemption, selector, operation and default" bash tools/check-namespace-guard.sh --selftest
run_gate "no immutable field changes between the baseline tag and the tree" bash tools/check-immutable-fields.sh
run_gate "no Job keeps its name when its image changes inside one version" bash tools/check-immutable-fields.sh --perturb-images
run_gate "every ServiceMonitor and PodMonitor selects something the layers render" bash tools/check-monitor-targets.sh
run_gate "the monitor-targets gate goes red on an unlabelled Service, a missing port and an unmatched PodMonitor" bash tools/check-monitor-targets.sh --selftest
run_gate "the immutable-field gate goes red on a changed Job template" bash tools/check-immutable-fields.sh --selftest
# The gate planner: its rules hold on fixtures, and the declarations in
# tools/gate-inputs.yaml name gates this script registers and paths the tree has, so a renamed gate
# or a moved fixture cannot quietly narrow what a pull request runs.
run_gate "the gate planner selects, shards and aggregates by its rules, and goes red on a broken partition" \
  python3 tools/gate-plan.py --selftest
run_gate "every gate-input declaration names a registered gate and a tracked path" \
  python3 tools/gate-plan.py check-inputs
# A gate is skipped only when it exits 2 AND printed a line starting "SKIPPED: <reason>"; a bare exit 2
# (a syntax error, a grep on a missing file, a usage error) is a failure. Planted gates show each case,
# and mutated copies of this script that book every exit 2 as skipped must go red.
run_gate "check-all books a skip only on a SKIPPED: line, and a bare exit 2 as a failure" bash tools/check-all-selftest.sh
run_gate "every action is SHA-pinned and every CI download is checksummed" bash tools/check-action-pins.sh
run_gate "the action-pin gate goes red on a moving tag and an unchecked download" bash tools/check-action-pins.sh --selftest
run_gate "observability off: refused without the profile, zero monitors with it, bring-your-own renders" bash tools/check-capability-monitors.sh
run_gate "the capability-monitors gate goes red on an ungated monitor" bash tools/check-capability-monitors.sh --selftest
run_gate "the rendered tree reaches no unlisted external host, and audited phone-homes are off or listed" bash tools/check-cloud-egress.sh
run_gate "the cloud-egress gate goes red on an unlisted host and a phone-home turned on" bash tools/check-cloud-egress.sh --selftest
run_gate "no Tockmox-owned pod uses the default ServiceAccount or an unlisted API token" bash tools/check-sa-tokens.sh
run_gate "the service-account token gate goes red on a default account, a missing field and an unlisted token" bash tools/check-sa-tokens.sh --selftest
run_gate "every rendered container has a memory limit or a written reason" bash tools/check-memory-limits.sh
run_gate "the memory-limit gate goes red on a dropped limit, a new container and a stale residue entry" bash tools/check-memory-limits.sh --selftest
run_gate "the alert bridge logs each delivery, ntfy stays single-replica, drill rows name their backup" bash tools/check-notify-and-drill.sh
run_gate "the notify-and-drill gate goes red on every mutation" bash tools/check-notify-and-drill.sh --selftest
# The release bar kept as data (tools/release-bars.yaml) says what RELEASING.md says. Not in
# ci.yaml yet, for the reason at the top of this file.
run_gate "the release bar in tools/release-bars.yaml agrees with RELEASING.md" bash tools/check-release-bars.sh
run_gate "the release-bars gate goes red on a missing row, a drifted cell and a missing file" bash tools/check-release-bars.sh --selftest
# (REQ-0004 AC-4.1, ruled 2026-10-08): the gateway is the shipped
# default and the console goes through it on a chart-minted key. Not in
# ci.yaml yet, for the reason at the top of this file.
run_gate "the model gateway is the shipped default, the console goes through it, the console-key Job is scoped, a site may override" bash tools/check-gateway-default.sh
run_gate "the gateway-default gate goes red on every mutation" bash tools/check-gateway-default.sh --selftest
run_gate "the resilient profile refuses an in-cluster backup target and keeps its drill alarm with the drill off" bash tools/check-resilient-profile.sh
run_gate "the resilient-profile gate goes red on every mutation" bash tools/check-resilient-profile.sh --selftest
run_gate "global.imageRegistry redirects every image" bash tools/check-airgap.sh
# the five surfaces of a disconnected install are declared in
# tools/airgap-manifest.yaml, and the table at the top of airgap.md is generated from it.
run_gate "the five air-gap surfaces are declared once, every tool and step exists, and airgap.md's table matches" bash tools/check-airgap-manifest.sh
run_gate "the air-gap manifest gate goes red on a missing tool, a dangling step, an unnamed prerequisite and a stale table" bash tools/check-airgap-manifest.sh --selftest
# The docs-site gates. The selftest needs only python3; the main run builds the
# site and skips (2) when the pinned MkDocs toolchain is not installed, because a
# laptop without a docs venv is not a tree with a defect. See
# tools/check-docs-offline.sh for why it reads the built files and not the config.
run_gate "the docs offline gate goes red on every external reference" \
  bash tools/check-docs-offline.sh --selftest
serial_gate "the built documentation site makes no network request" \
  bash tools/check-docs-offline.sh
run_gate "the committed SBOM matches the tree" bash tools/gen-sbom.sh --check
run_gate "the committed images.txt matches the charts" bash tools/gen-images.sh --check
run_gate "documentation stamps are current" bash tools/stamp-docs.sh --check
# The layer table and the four section READMEs are generated. The
# selftest proves the check goes red on a flipped wave, a flipped installer
# mapping, a hand-edited table and an unlisted page.
run_gate "the docs index surfaces match a fresh render" bash tools/gen-docs-index.sh --check
run_gate "the docs index check goes red on drift" bash tools/gen-docs-index.sh --selftest
run_gate "no site specifics in the published tree" bash tools/check-no-site-specifics.sh
run_gate "no workflow publishes a container image (ADR-0036)" bash tools/check-no-published-images.sh
run_gate "the no-published-images gate goes red on every push pattern (ADR-0036)" bash tools/check-no-published-images.sh --selftest
# The docs publish path: the content gate refuses anything that is not
# static web content, and the publish script is run against a stub kubectl.
serial_gate "the built documentation site holds only static web content" bash tools/check-docs-site-contents.sh
serial_gate "the docs site-contents gate goes red on every non-static file" bash tools/check-docs-site-contents.sh --selftest
serial_gate "the docs publish script refuses what it must and always removes its pod" bash tools/publish-docs.sh --selftest
run_gate "documentation style" bash tools/check-docs-style.sh
run_gate "documented commands paste as-is" bash tools/check-pasteable-blocks.sh
# NEVER run_gate THIS EITHER. Reporting mode is deliberate and stays: `--enforce`
# refuses any unclassified block on the three critical-path pages, and today that
# is all 120 of them, so turning it on here would go red on day one ... which is
# exactly how a gate earns an exemption list and then stops being believed. The
# migration flips this to --enforce page by page. Until then the number belongs
# in every run's output and cannot be lost: staged enforcement is defensible,
# staged awareness is not.
#
# What changed 2026-09-15 is only the ACCOUNTING. Until then this was a
# `run_gate`, so a line that reports and never tests was counted in the "passed"
# total alongside gates that can go red ... the identical defect this file already
# fixed for kubeconform fourteen lines below, for the reason written there. Found
# by mutation-testing all 24 gates: 22 went red for the right reason, 2 correctly
# refused to run, and this one could not fail under any tree state because it is
# not trying to.
#
# So: the scan still runs, its number still prints, and it counts as SKIPPED
# rather than passed. Flipping it back to a gate is the --enforce migration's
# job, not an accounting change.
# It goes through run_gate only to keep its place in a parallel run's ordered report, and it
# EXITS 2 whatever the inventory says: counted as skipped, exactly as before, never as a pass.
run_gate "every documented block is accounted for" bash -c '
  bash tools/check-block-inventory.sh || true
  printf "  NOT A GATE: reported, never enforced. No tree state changes this line.\n"
  printf "  Enforcement is per-page and carded; \`--enforce\` is the real check.\n"
  printf "SKIPPED: reported, never enforced; enforcement is per-page (check-block-inventory.sh --enforce)\n"
  exit 2'

run_gate "docs links resolve" bash tools/check-docs-links.sh
run_gate "frontmatter contract holds" bash tools/check-frontmatter.sh
# ci.yaml's "every layer renders a non-zero number of resources", which had no
# twin here until this gate was added. It also writes build/render-counts.tsv, which the
# next gate reads, so it must stay ahead of it.
serial_gate "every layer renders a non-zero number of resources" bash tools/render-counts.sh
serial_gate "documented counts still match the tree" bash tools/check-doc-claims.sh
# Both halves here, unlike ci.yaml, which splits them across two jobs because
# only one of them fetches tags. A laptop clone usually has them, and when it
# does not this reports the drift half as skipped rather than failing the run.
run_gate "values stability tiers hold" bash tools/check-values-tiers.sh
# ci.yaml's "values schema rejects an unknown top-level key or component name"
# step. That step used to be inline in ci.yaml and had no twin here, so
# a contributor could pass this script and fail CI on it.
run_gate "values schema rejects a misspelt key or component" bash tools/check-values-typos.sh
run_gate "check-values-typos selftest" bash tools/check-values-typos.sh --selftest
# The config half runs anywhere helm does. The forced-failure half
# needs the litellm CLI (LITELLM_BIN) and reports SKIPPED without it;
# .github/workflows/policy-gate.yaml installs it and always runs both.
# ci.yaml's "the Tockmox UI's tests pass". Exit 2 (skipped) without the UI's
# packages: TOCKMOX_UI_PYTHON names a venv that has them (the script says how).
run_gate "the Tockmox UI's tests pass" bash tools/check-tockmox-ui-tests.sh
# The AI nodes' generated desired.yaml equals what its inputs render, and the renderer refuses what it should.
# Exit 2 (skipped) without PyYAML and jsonschema: TOCKMOX_UI_PYTHON names a venv that has them.
run_gate "every AI node's desired.yaml is what its inputs render" bash tools/check-ai-node-render.sh
run_gate "the ai-node render gate goes red on a stale file, an unpinned revision, a port collision and a misspelt key" bash tools/check-ai-node-render.sh --selftest
run_gate "the policy gate refuses every bad config by name" bash tools/check-policy-gate.sh
run_gate "the policy gate holds with the local backend down" bash tests/policy-gate/run.sh
# Real-binary proofs: exit 2 (skipped) without the litellm CLI and Postgres binaries, or
# without a Smokescreen binary (SMOKESCREEN_BIN); each script says how to get them.
run_gate "the key policy's unit tests" bash -c 'python3 -c "import pytest" 2>/dev/null || { echo "SKIPPED: no pytest for python3"; exit 2; }; python3 -m pytest -q tests/key-policy/test_key_policy.py'
run_gate "the key policy refuses every bad key write, and the red leg reopens without it" bash tests/key-policy/run.sh
# The identity layer's open-applications job: its listing and its PATCH run on stand-ins, the console's fixtures are
# what it writes, and its render is scoped to one ConfigMap (each widening planted and caught).
run_gate "the open-applications job lists every unbound application, writes one ConfigMap and is scoped to it" bash -c 'python3 -c "import pytest, yaml" 2>/dev/null || { echo "SKIPPED: no pytest or PyYAML for python3"; exit 2; }; python3 -m pytest -q -p no:cacheprovider tests/identity-open-applications'
run_gate "the rendered agent-egress proxy refuses what it must, in a real Smokescreen" bash tests/agent-egress/proxy-proof.sh

# NOT a tools/check-*.sh script, and included anyway. CONTRIBUTING.md points
# contributors at this one command, so a gate that runs in ci.yaml and not here
# sends someone to a red build after a green local run. That is how a gate stops
# being believed. It is hermetic and takes about two seconds, so it belongs in
# the same breath as the static ones even though it runs a program rather than
# reading the tree. See tests/installer/README.md.
run_gate "the installer behaves, interactively and from a config file" bash tests/installer/run.sh

have gitleaks \
  && run_gate "gitleaks" gitleaks detect --source . --redact --exit-code 1 \
  || skip_gate "gitleaks" "binary not installed; CI runs it over full history"

# KUBECONFORM, RUN FOR REAL. Until 2026-09-13 the line here printed a
# green "kubeconform" from a hardcoded `exit 0`, a gate that could not fail; it
# was then a SKIP in both branches until the render pipeline was wired here.
# Now ci.yaml's "kubeconform rendered output" step and this line both call
# tools/check-kubeconform.sh, so they run one pipeline. Without the binary it
# reports skipped (exit 2), never passed; with it, a chart where kubeconform
# validated nothing (schemas unreachable) fails rather than reading as green.
# The selftest is what proves the line can go red.
run_gate "kubeconform -strict over every layer's render" bash tools/check-kubeconform.sh
run_gate "the kubeconform gate goes red on an unknown field, a wrong type and empty input" bash tools/check-kubeconform.sh --selftest

# --------------------------------------------------------------------- result
[ "$LIST_ONLY" = 1 ] && exit 0
if [ "$JOBS" -gt 1 ]; then
  barrier
  for f in "$SLOTS"/*.name; do
    [ -e "$f" ] || continue
    b="${f%.name}"; n="$(cat "$f")"
    rc="$(cat "$b.rc" 2>/dev/null || echo 1)"
    printf '\n=== %s === (%ss)\n' "$n" "$(cat "$b.secs" 2>/dev/null || echo '?')"
    cat "$b.log" 2>/dev/null
    [ -e "$b.rc" ] || echo "  (no exit status recorded: the gate's runner died)"
    [ "$rc" = 124 ] && [ "$GATE_TIMEOUT" -gt 0 ] && n="$n (TIMEOUT after ${GATE_TIMEOUT} s)"
    tally "$n" "$rc" "$b.log"
    IFS=$'\t' read -r k_ord k_key < "$b.key"
    result_row "$k_ord" "$k_key" "$(gate_status "$rc" "$b.log")" "$rc" "$(cat "$b.secs" 2>/dev/null || echo -)" "$(cat "$f")"
  done
  printf '\nSlowest gates:\n'
  for f in "$SLOTS"/*.secs; do printf '%6ss  %s\n' "$(cat "$f")" "$(cat "${f%.secs}.name")"; done | sort -rn | head -5
fi
TREE_AFTER="$(tree_fingerprint)"
if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then
  printf '\nA GATE CHANGED THE CHECKOUT. Running gates at once is only safe when none writes into the tree;\n'
  printf 'this one did (git status before and after differ). Re-run with CHECK_ALL_JOBS=1 and fix the gate.\n'
  diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") | head -20
  fail=$((fail + 1)); failed_names="${failed_names}
  - the checkout is unchanged by the gates"
fi
mkdir -p "$(dirname "$RESULTS")"
{ printf 'ord\tkey\tstatus\trc\tseconds\tname\n'; sort -n "$SLOTS/results" 2>/dev/null; } > "$RESULTS"
if [ "$skipped" -gt 0 ]; then
  printf '\nSkipped, which is not passed (each said SKIPPED: and why):%s\n' "$skipped_names"
fi
if [ "$unselected" -gt 0 ]; then
  printf '\nNot run, because none of their declared inputs changed since %s (tools/gate-inputs.yaml):%s\n' \
    "$CHANGED_FROM" "$unselected_names"
fi
printf '\n----------------------------------------------------------------\n'
printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$unselected" -gt 0 ] && printf '%s not selected (inputs unchanged)\n' "$unselected"
[ "$othershard" -gt 0 ] && printf '%s on other shards (%s)\n' "$othershard" "$SHARD"
printf 'Results: %s\n' "$RESULTS"

# The evidence beside the rows: which commit, from a clean checkout or not, in which mode.
# Written before the verdict is printed, with the exit status the verdict below returns.
if [ "$fail" -ne 0 ]; then final_rc=1
elif [ "$STRICT" = 1 ] && { [ "$skipped" -gt 0 ] || [ "$unselected" -gt 0 ]; }; then final_rc=2
else final_rc=0; fi
RESULTS_META="${RESULTS%.tsv}.meta.json"
python3 -c '
import json, sys
k = ["head_sha", "dirty_paths", "strict", "changed_from", "shard", "passed", "failed", "skipped", "unselected", "othershard", "exit"]
v = dict(zip(k, sys.argv[2:]))
for n in ("dirty_paths", "passed", "failed", "skipped", "unselected", "othershard", "exit"):
    v[n] = int(v[n])
v["clean"] = v["dirty_paths"] == 0
v["strict"] = v["strict"] == "1"
json.dump(v, open(sys.argv[1], "w"), indent=1, sort_keys=True)
' "$RESULTS_META" "$START_HEAD" "${START_DIRTY:-0}" "$STRICT" "$CHANGED_FROM" "$SHARD" \
  "$pass" "$fail" "$skipped" "$unselected" "$othershard" "$final_rc" \
  || { echo "check-all.sh: could not write $RESULTS_META"; final_rc=1; }
printf 'Evidence: %s (commit %s, %s)\n' "$RESULTS_META" "${START_HEAD:-<none>}" \
  "$([ "${START_DIRTY:-0}" = 0 ] && echo 'clean checkout' || echo "${START_DIRTY} path(s) differed from it when the run started")"

if [ "$fail" -ne 0 ]; then
  printf 'FAILED:%s\n' "$failed_names"
  exit 1
fi
if [ "$final_rc" = 2 ]; then
  printf '\nBLOCKED (strict): %s skipped and %s not selected. In strict mode a gate that did not run is\n' "$skipped" "$unselected"
  printf 'not green; give each skipped gate what it said it lacked, and run every gate (no --changed-from).\n'
  exit 2
fi
if [ "$final_rc" != 0 ]; then
  exit "$final_rc"
fi
if [ "$unselected" -gt 0 ] || [ "$othershard" -gt 0 ]; then
  echo "All selected static gates passed. A run with no arguments runs every gate."
else
  echo "All runnable static gates passed."
fi
echo
echo "Not covered here, and not passed by this run: DCO sign-off, full-history"
echo "secret scanning, and every documented path in tests/executed-docs/."

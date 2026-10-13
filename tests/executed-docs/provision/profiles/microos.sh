#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# openSUSE MicroOS provisioner profile for the executed-docs harness.
#
# WHY THIS FILE EXISTS, in the harness's own words. `INVENTORY.md` row A8 says
# of the immutable-OS exception: "The harness's guest is an Ubuntu cloud image,
# so no run of this harness is evidence for any immutable OS ... What would
# change it: a MicroOS image in the substrate's image store and a second
# provisioner profile. That is the single highest-value addition to this
# harness, because it is the environment the reference deployment actually
# uses." The image landed 2026-09-11 (`tockmox-test/microos-cloud`). This is the
# second provisioner profile, and `throwaway-cluster.sh create` delegates to it
# whenever the image resolves to MicroOS (TM-0715).
#
# THE TRAP THIS PROFILE EXISTS TO AVOID, and it is the whole point of the file.
# Every step MicroOS needs is already written in `fresh-install.md`: the
# `transactional-update pkg install` and its `sudo reboot` (section 2), the
# `INSTALL_K3S_SKIP_SELINUX_RPM` pair and the `restorecon` (section 4a). If the
# cloud-init were hand-written from what an author knows about MicroOS, the run
# would test that knowledge and prove nothing about the page ... a green run
# would be entirely compatible with the documentation being wrong, which is the
# one outcome this harness exists to prevent. So every documented command is
# EXTRACTED with `lib/extract-block.sh` at a git ref, exactly as every other
# path does it, and this file REFUSES rather than substituting a command of its
# own when an extraction does not resolve.
#
# Contrast with the Ubuntu lane, which is honest about this in its own comment:
# `throwaway-cluster.sh` hand-writes its k3s line and carries the note "Keep
# these in step with fresh-install.md step 4a. If that page changes its flags,
# this line is the second edit." That coupling is exactly what drifts. Nothing
# in this profile needs a second edit when the page changes, because nothing
# here holds a copy of a documented command. That includes the k3s VERSION:
# section 4 pins one in its "Set these on each node" block, and this profile
# runs that block, so the guest gets the version the page tells a reader to use
# rather than whatever the stable channel says today.
#
# WHAT RUN 1 TAUGHT (2026-09-17, guest tm0715-microos-01), carried forward here
# because all three lessons are cheap to honour and expensive to rediscover:
#
#   1. IT REPORTED ONCE AND WENT DARK FOR AN HOUR. With no console on this lane
#      a silent guest is indistinguishable from a dead one, a slow one, and a
#      finished one. Every long step here runs under a heartbeat that beacons
#      every 60 seconds with the process table and the transactional-update
#      log, so "stuck" and "working" stop looking the same.
#
#   2. THE PHASE MARKER LIVED IN /etc, WHICH IS NOT SAFE ON A TRANSACTIONAL OS.
#      `fresh-install.md` section 2 explains that transactional-update branches
#      from the snapshot you are RUNNING and whichever change lands second
#      wins. Each snapshot carries its own /etc overlay, so anything written to
#      /etc before the documented reboot can be gone after it. The driver and
#      every marker live under /var/lib, on the shared subvolume, and the
#      driver is invoked from /var/lib/cloud/scripts/per-boot/, which
#      cloud-init runs on EVERY boot ... which is what carries the run across
#      the reboot the page itself prescribes.
#
#   3. EVERY curl HAS --max-time. Run 1's beacon had none, so a beacon that
#      could not reach the apiserver would have hung rather than failed, and a
#      hang looks exactly like the silence in lesson 1.
#
# AND WHAT RUN 2 (tm0715b) GOT RIGHT THAT THE FIRST DRAFT OF THIS FILE DROPPED,
# found 2026-09-23 while wiring it, recorded so it is not dropped a third time:
#
#   4. BLOCKS RUN AS THE UNPRIVILEGED USER, NOT AS ROOT. The page is written
#      for a person with sudo, and two defects this lane has already found only
#      exist for that person (TM-0622, sudo's secure_path omits /usr/local/bin;
#      TM-0630, section 2's success condition for a non-root PATH). A driver
#      invoked by cloud-init runs as root, so running a block with plain `bash`
#      would quietly hide exactly that class. Every block goes through
#      `runuser -u $RUN_AS`.
#
#   5. THE SUCCESS CONDITION IS A POINT-IN-TIME READ. Section 4a's
#      `k3s kubectl get nodes` run the instant the install returns reads
#      NotReady, which is not a finding about the page. The driver polls it
#      until Ready or a budget runs out, then runs it ONCE MORE and records
#      THAT run, so what is reported is the page's own command and output.
#
#   6. THE FIRST DRAFT'S `s2-iscsid` WAS THE WRONG BLOCK. It selected
#      `--containing iscsiadm`, which matches section 2's SUCCESS CONDITION,
#      not the post-reboot `sudo systemctl enable --now iscsid` it was named
#      for. So the documented enable never ran, and the success condition would
#      have reported iscsid's default state as the page's result ... a harness
#      step skipped, reported as a documentation defect. The enable block could
#      not be selected by content (four blocks in the section carry it) or by
#      label (its nearest prose line was shared), which was TM-0721, so run 2
#      selected it by an ordinal confirmed by content. The page now labels it
#      `**NODE** ... every node, on MicroOS`, the form the section's other
#      MicroOS-only blocks already used, and it is selected by that label ANDed
#      with its content. No block in this profile is selected by ordinal, and
#      the extraction loop refuses one.
#
# NOTHING IS TRANSCRIBED. Until TM-0722 one command was: fresh-install section
# 2's `sudo systemctl disable --now transactional-update.timer
# rebootmgr.service`, which the page prescribes for exactly this case ("For a
# time-boxed build or a release gate, hold both off until you are done") but
# which `extract-block.sh` could not see, because its fence is indented inside a
# list item and the extractor then only counted fences at column 0. The
# extractor now reads indented fences and removes their indent, so the hold is
# extracted like every other block (`s2-timer-hold`). Seeing that block also
# made `--containing transactional-update` ambiguous, since the hold carries the
# same string: `s2-pkg` was unique only because the extractor was half-blind,
# and it now names the install command itself.
#
# ONE VALUE IS SUPPLIED, and it is the page's own YOU SUPPLY: section 4's
# `YOUR_API_HOSTNAME`. It is replaced with the guest's hostname and the
# substitution is recorded in provenance with both fingerprints, page bytes and
# executed bytes, so a reader can see exactly what differed.
#
# WHAT A RUN OF THIS PROFILE DOES NOT PROVE. It says nothing about a
# conventional distribution, and nothing on amd64-versus-arm64 grounds beyond
# what the harness README already bounds. `create` stops at a Ready k3s node:
# no Tockmox chart is installed, so section 5's and section 6's blocks are
# untested by the profile itself and TM-0628's metrics Services remain owed ...
# though run.sh can now run its paths against a MicroOS guest, which it never
# could before.

# NO `set -e`/`set -u` HERE ON PURPOSE. This file is SOURCED by
# throwaway-cluster.sh, and shell options set at the top of a sourced library
# silently change the caller's error behaviour ... a library that turns on
# `errexit` in its consumer is a defect that only shows up in the consumer's
# unrelated code paths. The guest-side scripts this file emits set their own
# options, where they are scoped to the process that runs them.

# ---- the blocks this profile executes, and how each one is selected ---------
# Selector discipline, from lib/extract-block.sh's own guidance: prefer
# --containing over --block, because an ordinal is a position and a position
# moves when anyone inserts a block above it. Where two blocks are
# byte-identical apart from one flag (section 4a's two cluster shapes), only
# --under-label can express which one is meant, so the label names the shape.
# Where a label is shared by several blocks (section 2's `every node, on
# MicroOS` carries the snapshot check, the timer hold and the post-reboot
# enable), the sixth column ANDs a --containing onto it, so the label picks the
# group and the content picks the block. --block is refused: an ordinal is a
# position, and TM-0721 removed the last one this profile used.
#
# Verified resolving against the working tree on 2026-09-23 (TM-0721/TM-0722).
# An ambiguous or missing selector is a REFUSAL below, never a fallback.
MICROOS_FRESH_INSTALL_PAGE="docs/deployment/fresh-install.md"
MICROOS_UNINSTALL_PAGE="docs/operations/uninstall.md"
MICROOS_EXTINT_PAGE="docs/administration/external-integrations.md"
MICROOS_S2_SECTION="## 2. Install the storage packages, on every node"
MICROOS_S4_SECTION="## 4. Install k3s"
MICROOS_S4A_SECTION="### 4a. The first server ... BOTH SHAPES, on node 1"
MICROOS_S4E_SECTION="### 4e. Finish every node ... BOTH SHAPES"
MICROOS_XI_SECTION="### 3. Point containerd at Harbor, on every node"
MICROOS_U9_SECTION="## 9. Removing k3s itself ... optional, and the reboot a transactional OS may need"

# The page's own blank. Replaced with the guest's hostname; see the header.
MICROOS_YOU_SUPPLY_PLACEHOLDER="YOUR_API_HOSTNAME"

# name|page|section|selector-flag|selector-value|and-containing (optional)
# Kept as data rather than as a sequence of calls so the provenance file and the
# extraction loop cannot disagree about what was run.
microos_block_table() {
  cat <<TABLE
s2-timer-hold|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S2_SECTION}|--containing|systemctl disable --now transactional-update.timer rebootmgr.service|
s2-pkg|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S2_SECTION}|--containing|transactional-update --non-interactive pkg install|
s2-iscsid|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S2_SECTION}|--under-label|every node, on MicroOS|systemctl enable --now iscsid
s2-success|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S2_SECTION}|--containing|systemctl is-active iscsid|
s4-exports|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S4_SECTION}|--containing|export K8S_API_NAME=${MICROOS_YOU_SUPPLY_PLACEHOLDER}|
s4a-install|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S4A_SECTION}|--under-label|One node, on openSUSE MicroOS|
s4a-restorecon|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S4A_SECTION}|--containing|restorecon|
s4a-success|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S4A_SECTION}|--containing|k3s kubectl get nodes|
s4e-success|${MICROOS_FRESH_INSTALL_PAGE}|${MICROOS_S4E_SECTION}|--containing|k3s kubectl version|
xi-crictl|${MICROOS_EXTINT_PAGE}|${MICROOS_XI_SECTION}|--containing|k3s crictl pull|
un9-confirm|${MICROOS_UNINSTALL_PAGE}|${MICROOS_U9_SECTION}|--containing|btrfs subvolume get-default|
TABLE
}

# WHY THERE IS NO EXTRACTED TEARDOWN COMMAND, recorded so its absence is not
# read as an oversight. uninstall.md section 9 states plainly that "k3s ships
# its own uninstaller and this page does not duplicate it" ... it documents one
# PROPERTY of that uninstaller (the transactional-update snapshot and the reboot
# it may stage) and never presents `k3s-uninstall.sh` as a runnable block. So
# the teardown invocation is k3s's command and not Tockmox's, it is scaffolding
# here rather than a documented step under test. What IS under test is the
# page's decision rule ("Read the last few lines rather than assuming which
# case you are in") and its confirmation block (un9-confirm): the driver reads
# the uninstaller's last lines exactly as the page tells a reader to, reboots
# only if the page's rule says one was staged, and then runs the block.
MICROOS_TEARDOWN_SCAFFOLD='sudo /usr/local/bin/k3s-uninstall.sh'

# ---- extraction ------------------------------------------------------------
# A stock Mac has `shasum` and no `sha256sum`; the sandbox has the reverse.
# extract-block.sh already carries the same fallback for its --sha mode.
microos_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}

# Writes one file per block plus PROVENANCE.tsv. Refuses on any selector that
# does not resolve to exactly one block: an ambiguous needle means the page
# gained a second block that matches, and guessing between them is precisely
# the drift this harness exists to catch.
#
# Must be run with the current directory inside the repository whose docs are
# under test: the extractor reads pages with `git show REF:PAGE`.
microos_extract_blocks() {
  local ref="$1" outdir="$2"
  local lib_dir extractor
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)"
  extractor="${lib_dir}/extract-block.sh"

  if [ ! -x "$extractor" ] && [ ! -f "$extractor" ]; then
    echo "REFUSING: extractor not found at ${extractor}" >&2
    return 2
  fi

  mkdir -p "${outdir}/blocks"
  : > "${outdir}/PROVENANCE.tsv"
  printf 'name\tpage\tsection\tselector\tvalue\tsha256\tsource\n' >> "${outdir}/PROVENANCE.tsv"

  # MICROOS_PAGE_ROOT is for selftest.sh only: it reads the pages from a
  # directory of fixtures instead of from git, so the refusals below can be
  # proven against a page that has deliberately moved a block. A real run never
  # sets it, and `create` does not pass it through.
  local name page section flag value also body sha source
  local -a src sel
  while IFS='|' read -r name page section flag value also; do
    [ -n "$name" ] || continue
    if [ "$flag" = "--block" ]; then
      # An ordinal is a position, and a position moves when anyone inserts a
      # block above it. See the header, lesson 6 (TM-0721).
      echo "REFUSING: ${name} is selected by --block ${value}. This profile selects" >&2
      echo "          by label or content only; name the block, not its position." >&2
      return 3
    fi
    if [ -n "${MICROOS_PAGE_ROOT:-}" ]; then
      src=(--file "${MICROOS_PAGE_ROOT}/${page}")
    else
      src=(--ref "$ref" --page "$page")
    fi
    sel=("$flag" "$value")
    [ -z "$also" ] || sel+=(--containing "$also")
    if ! body="$(bash "$extractor" "${src[@]}" \
                   --section "$section" --lang bash "${sel[@]}" 2>"${outdir}/blocks/${name}.err")"; then
      echo "REFUSING: extraction failed for ${name} (${flag} '${value}'${also:+ and --containing '${also}'} in ${page})" >&2
      echo "          $(cat "${outdir}/blocks/${name}.err")" >&2
      echo "          A failed selector means the page moved. Fix the selector," >&2
      echo "          never substitute a hand-written command for the block." >&2
      return 3
    fi
    source="extracted@${ref}"
    [ -z "$also" ] || value="${value} AND --containing ${also}"
    printf '%s\n' "$body" > "${outdir}/blocks/${name}.sh"
    sha="$(printf '%s\n' "$body" | microos_sha256)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$page" "$section" "$flag" "$value" "$sha" "$source" \
      >> "${outdir}/PROVENANCE.tsv"
    rm -f "${outdir}/blocks/${name}.err"
  done < <(microos_block_table)

  echo "extracted $(( $(wc -l < "${outdir}/PROVENANCE.tsv") - 1 )) block(s) at ref ${ref} -> ${outdir}/blocks" >&2
}

# ---- the page's YOU SUPPLY -------------------------------------------------
# Replaces the placeholder in the exports block with the value the page asks
# the reader for, and records it. Refuses unless the placeholder occurs exactly
# once: zero means the page changed its blank, two means a substitution would
# touch something the page did not mark as the reader's.
microos_you_supply() {
  local outdir="$1" api_name="$2"
  local f="${outdir}/blocks/s4-exports.sh" n
  n="$(grep -o "$MICROOS_YOU_SUPPLY_PLACEHOLDER" "$f" | wc -l | tr -d ' ')"
  if [ "$n" != "1" ]; then
    echo "REFUSING: s4-exports carries ${n} occurrence(s) of ${MICROOS_YOU_SUPPLY_PLACEHOLDER}, not 1." >&2
    return 3
  fi
  case "$api_name" in
    ''|*[!a-z0-9.-]*) echo "REFUSING: API name '${api_name}' is not a plain DNS name." >&2; return 3 ;;
  esac
  sed -i.page "s/${MICROOS_YOU_SUPPLY_PLACEHOLDER}/${api_name}/" "$f"
  rm -f "${f}.page"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "s4-exports" "$MICROOS_FRESH_INSTALL_PAGE" "$MICROOS_S4_SECTION" "--you-supply" \
    "${MICROOS_YOU_SUPPLY_PLACEHOLDER} -> ${api_name}" \
    "$(microos_sha256 < "$f")" \
    "YOU-SUPPLY (executed bytes; the extracted row above is the page's)" \
    >> "${outdir}/PROVENANCE.tsv"
}

# ---- the runtime environment the guest scripts read ------------------------
# WHY THIS EXISTS AS A FILE rather than as interpolation. Every guest script
# below is emitted from a QUOTED heredoc, so the build substitutes nothing and
# what ships is exactly what was written here ... the same reason the Ubuntu
# lane puts its commands in block scalars: an earlier version of that lane
# inlined a value into a double-quoted YAML scalar, produced an invalid escape,
# and cloud-init rejected the whole document and ran NOTHING, with no error
# anywhere the harness could see. Quoted heredocs make that class of bug
# impossible, and the cost is that runtime values have to arrive by another
# route. This is that route, and it is sourced first by every guest script.
#
# It also means the scripts FAIL LOUDLY rather than silently: they run under
# `set -u`, so a value this file forgets is an immediate unbound-variable error
# on the guest's own console, not a beacon that quietly names the wrong
# ConfigMap.
#
# Values are checked here rather than trusted, because they land inside single
# quotes in a file the guest sources: a quote in any of them would be a
# different program.
microos_env_file() {
  local prefix="$1" beacon_api="$2" beacon_ns="$3" run_as="$4" ready_budget="$5"
  local v
  for v in "$prefix" "$beacon_api" "$beacon_ns" "$run_as" "$ready_budget"; do
    case "$v" in
      *"'"*|*'\'*|'') echo "REFUSING: env value '${v}' is empty or carries a quote" >&2; return 2 ;;
    esac
  done
  cat <<ENVFILE
# Scaffolding inputs for the MicroOS profile. Sourced by driver, heartbeat,
# beacon and handoff. Nothing here is a documented command, and nothing here
# is a value the page asks the reader for ... those live in blocks/s4-exports.sh.
export PREFIX='${prefix}'
export BEACON_API='${beacon_api}'
export BEACON_NS='${beacon_ns}'
# The unprivileged user every documented block runs as. See lesson 4.
export RUN_AS='${run_as}'
# Seconds to wait for section 4a's success condition to read Ready.
export READY_BUDGET='${ready_budget}'
ENVFILE
}

# ---- the guest-side driver -------------------------------------------------
# A state machine in /var/lib/tockmox-harness/state, advanced on every boot by
# cloud-init's per-boot hook:
#
#   1      timer hold, then section 2's package block, whose last line reboots
#   2      post-reboot: section 2's enable and success condition, section 4's
#          exports and 4a's install, restorecon and success condition, then the
#          kubeconfig handoff ... and `create` on the harness side returns
#   ready  the cluster is the harness's. A transient unit waits for the
#          harness to ask for the uninstall proof (`uninstall-proof` verb)
#   3      k3s's uninstaller has run; the page's decision rule picks the branch
#   3r     the page's rule said a snapshot was staged, so we rebooted into it
#   done   uninstall.md section 9's confirmation block has run
#
# Markers are written BEFORE the step that may reboot: a reboot that lands
# mid-block must not look like a phase that never started.
microos_driver() {
  cat <<'DRIVER'
#!/bin/bash
# Scaffolding. Nothing here is under test; the files in $H/blocks are.
set -u
H=/var/lib/tockmox-harness
. "$H/env"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$H/out"
exec >>"$H/out/driver.log" 2>&1
MODE="${1:-per-boot}"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
echo "=== driver ${MODE} $(date -u +%FT%TZ) pid=$$ boot=${BOOT_ID} ==="

exec 9>"$H/driver.lock"
if [ "$MODE" = "await-go" ]; then
  # The per-boot driver that spawned this still holds the lock for a moment.
  flock 9
else
  flock -n 9 || { echo "another driver holds the lock, exiting"; exit 0; }
fi
echo "${MODE} boot=${BOOT_ID} $(date -u +%FT%TZ)" >> "$H/out/invocations"

state()    { cat "$H/state" 2>/dev/null || echo 1; }
setstate() { echo "$1" > "$H/state"; sync; echo "state -> $1"; }
# `9>&-` on everything this script starts, here and below: the lock is this
# process's, and a child that inherits fd 9 holds it for as long as it lives. A
# heartbeat's orphaned `sleep 60` held it for up to a minute; SELinux also
# refuses the write when a confined helper (`ip`, as ifconfig_t) inherits it,
# which is an AVC denial in the audit log on every run for no reason.
beacon()   { "$H/beacon.sh" "$@" 9>&-; }

# Beacon names are ConfigMap names: lowercase, digits, dashes, dots.
cmname() { printf '%s' "$1" | tr 'A-Z._' 'a-z--'; }

# Every documented block runs as the unprivileged user. See the profile
# header, lesson 4. stdout, stderr and exit status are recorded separately and
# beaconed IMMEDIATELY, so a block that ends in a reboot still reported what it
# could.
run_block() {
  local name="$1"
  echo "--- block ${name} start $(date -u +%FT%TZ) ---"
  runuser -u "$RUN_AS" -- bash "$H/blocks/${name}.sh" \
    > "$H/out/${name}.out" 2> "$H/out/${name}.err" 9>&-
  echo "$?" > "$H/out/${name}.rc"
  sync
  echo "--- block ${name} exit $(cat "$H/out/${name}.rc") ---"
  beacon "${PREFIX}-block-$(cmname "$name")" \
    out="$H/out/${name}.out" err="$H/out/${name}.err" rc="$H/out/${name}.rc"
}

snap() {
  {
    echo "=== $(date -u +%FT%TZ) state=$(state) mode=${MODE} boot=${BOOT_ID} ==="
    echo "--- os ---"; cat /etc/os-release; uname -a
    echo "--- btrfs default subvolume (the snapshot this boot is in) ---"
    btrfs subvolume get-default / 2>&1
    echo "--- packages section 2 asks for ---"
    rpm -q open-iscsi nfs-client cryptsetup 2>&1
    echo "--- invocations so far ---"; cat "$H/out/invocations"
    echo "--- did cloud-init's /etc survive into this boot? ---"
    ls -la /etc/rancher/k3s 2>&1
    echo "--- addressing ---"; ip -4 addr show; ip route show
  } > "$H/out/boot-$1.txt" 2>&1
}

hb_start() { "$H/heartbeat.sh" "$1" 9>&- & echo $! > "$H/heartbeat.pid"; }
hb_stop()  { [ -f "$H/heartbeat.pid" ] && kill "$(cat "$H/heartbeat.pid")" 2>/dev/null; rm -f "$H/heartbeat.pid"; }

spawn_await() {
  # A transient unit, not a background job: cloud-final is a oneshot, and
  # systemd kills whatever it leaves behind in its cgroup when it exits.
  #
  # THROUGH /bin/bash, NOT THE SCRIPT PATH, measured 2026-09-23 on run
  # tm0715-microos-05. MicroOS enforces SELinux, the script's label is
  # var_lib_t, and init_t may not EXECUTE var_lib_t: the unit failed
  # `203/EXEC ... Permission denied` (AVC denied { execute } for driver.sh) the
  # instant it started. cloud-init's per-boot hook can run the same file only
  # because cloud-init runs unconfined. It is the page's own section 4a lesson
  # (k3s fails 203/EXEC until restorecon) arriving through the scaffolding, and
  # systemd-run reported success because the unit STARTED. So the spawn is now
  # verified, not assumed: the waiter's first act is to beacon, and a waiter
  # that is not running a few seconds later is beaconed as a finding.
  systemctl stop tockmox-harness-await.service 2>/dev/null
  systemctl reset-failed tockmox-harness-await.service 2>/dev/null
  systemd-run --unit=tockmox-harness-await --collect /bin/bash "$H/driver.sh" await-go 9>&-
  sleep 5
  if systemctl is-active --quiet tockmox-harness-await.service; then
    echo "await-go running"
  else
    journalctl -u tockmox-harness-await.service --no-pager -n 20 > "$H/out/await-spawn.txt" 2>&1
    echo "await-go is NOT running"
    beacon "${PREFIX}-finding-await-not-running" journal="$H/out/await-spawn.txt"
  fi
}

confirm_and_finish() {
  run_block un9-confirm
  setstate "done"
  hb_stop
  beacon "${PREFIX}-complete" driver_log="$H/out/driver.log" outcome="$H/out/uninstall-outcome.txt"
  echo "=== complete $(date -u +%FT%TZ) ==="
}

if [ "$MODE" = "await-go" ]; then
  # ---- wait for the harness to ask for the uninstall proof ----------------
  if [ "$(state)" != "ready" ]; then echo "await-go in state $(state), nothing to do"; exit 0; fi
  T="$(cat "$H/beacon.token")"
  tls="-k"; [ -s "$H/beacon.ca.crt" ] && tls="--cacert $H/beacon.ca.crt"
  echo "waiting for ${BEACON_NS}/${PREFIX}-uninstall-go"
  beacon "${PREFIX}-await-running" invocations="$H/out/invocations"
  while :; do
    # shellcheck disable=SC2086
    code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' $tls \
      -H "Authorization: Bearer ${T}" \
      "${BEACON_API}/api/v1/namespaces/${BEACON_NS}/configmaps/${PREFIX}-uninstall-go" 2>/dev/null)"
    [ "$code" = "200" ] && break
    sleep 20
  done
  echo "go received $(date -u +%FT%TZ)"
  setstate 3
  beacon "${PREFIX}-uninstall-start" invocations="$H/out/invocations"
  hb_start phase3
  # Scaffolding: k3s's own uninstaller, run as the page's reader would run it.
  runuser -u "$RUN_AS" -- bash -c "$(cat "$H/teardown.SCAFFOLD.sh")" \
    > "$H/out/uninstall.out" 2> "$H/out/uninstall.err" 9>&-
  echo "$?" > "$H/out/uninstall.rc"
  sync
  # THE PAGE'S DECISION RULE, applied as the page states it: "Read the last few
  # lines rather than assuming which case you are in. `Discarding snapshot N`
  # and `New default snapshot is #N` are the two outcomes." Neither, or both,
  # is itself a finding about the page, and is recorded as one.
  staged=0; discarded=0
  grep -q 'New default snapshot is #' "$H/out/uninstall.out" "$H/out/uninstall.err" && staged=1
  grep -q 'Discarding snapshot' "$H/out/uninstall.out" "$H/out/uninstall.err" && discarded=1
  if   [ "$staged" = 1 ] && [ "$discarded" = 0 ]; then outcome=staged
  elif [ "$staged" = 0 ] && [ "$discarded" = 1 ]; then outcome=discarded
  else outcome="neither-or-both (staged=${staged} discarded=${discarded}): the page says these are unambiguous"
  fi
  echo "$outcome" > "$H/out/uninstall-outcome.txt"
  beacon "${PREFIX}-uninstall-done" out="$H/out/uninstall.out" err="$H/out/uninstall.err" \
    rc="$H/out/uninstall.rc" outcome="$H/out/uninstall-outcome.txt"
  if [ "$outcome" = "staged" ]; then
    setstate 3r
    hb_stop
    echo "page rule: a snapshot was staged, rebooting into it before the confirmation"
    sleep 3
    systemctl reboot
    exit 0
  fi
  confirm_and_finish
  exit 0
fi

case "$(state)" in
1)
  # ---- phase 1: the documented package install, which ends in a reboot ----
  snap 1
  beacon "${PREFIX}-boot-1" boot="$H/out/boot-1.txt" provenance="$H/PROVENANCE.tsv"
  hb_start phase1
  # The page prescribes holding both timers for a time-boxed build; without it
  # MicroOS's own updater can branch a snapshot underneath the run. Extracted
  # since TM-0722, like every other block.
  run_block s2-timer-hold
  # MARKER BEFORE THE BLOCK. The extracted block's last line is `sudo reboot`.
  setstate 2
  run_block s2-pkg
  # If we are still here two minutes later, the block did not reboot us: the
  # documented procedure did not happen as written, and that is a finding
  # rather than something to paper over.
  sleep 120
  hb_stop
  echo "phase 1 returned without a reboot; the page's own block ends in one"
  beacon "${PREFIX}-finding-no-reboot" driver_log="$H/out/driver.log"
  ;;
2)
  # ---- phase 2: post-reboot, the rest of the documented path --------------
  snap 2
  beacon "${PREFIX}-boot-2" boot="$H/out/boot-2.txt" \
    s2pkg_out="$H/out/s2-pkg.out" s2pkg_err="$H/out/s2-pkg.err"
  hb_start phase2
  run_block s2-iscsid
  run_block s2-success
  # Section 4 says to export its two values "at the start of your session" and
  # then run 4a in that same session. Sourcing the exports block and running
  # the install block in ONE shell IS that session; neither block's bytes are
  # touched. Section 4a's own `: "${K8S_API_NAME:?...}"` guards stay live, so a
  # missing export is refused by the page's guard, not pre-empted here.
  echo "--- block s4a-install (in s4-exports' session) start $(date -u +%FT%TZ) ---"
  runuser -u "$RUN_AS" -- bash -c ". '$H/blocks/s4-exports.sh' && bash '$H/blocks/s4a-install.sh'" \
    > "$H/out/s4a-install.out" 2> "$H/out/s4a-install.err" 9>&-
  echo "$?" > "$H/out/s4a-install.rc"
  sync
  beacon "${PREFIX}-block-s4a-install" \
    out="$H/out/s4a-install.out" err="$H/out/s4a-install.err" rc="$H/out/s4a-install.rc"
  run_block s4a-restorecon
  # Lesson 5: poll, then record one more run of the page's command.
  polls=0; ready=no
  deadline=$(( $(date +%s) + READY_BUDGET ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    polls=$((polls+1))
    runuser -u "$RUN_AS" -- bash "$H/blocks/s4a-success.sh" \
      > "$H/out/s4a-poll.out" 2> "$H/out/s4a-poll.err" 9>&-
    if grep -qw Ready "$H/out/s4a-poll.out"; then ready=yes; break; fi
    sleep 10
  done
  echo "ready=${ready} polls=${polls} budget=${READY_BUDGET}s" > "$H/out/s4a-ready-poll.txt"
  run_block s4a-success
  # TM-0622: the other documented `sudo /usr/local/bin/k3s` call sites a
  # one-node MicroOS guest can reach. 4e's server success condition is four
  # lines, three of them `sudo /usr/local/bin/k3s ...` (kubectl get nodes, get
  # pods, version) plus findmnt, run as the unprivileged user. The standalone
  # findmnt block (TM-0623) is the same command as the second line, and cannot
  # be selected on its own (the label and the content are both shared), so the
  # success block carries it.
  run_block s4e-success
  run_block xi-crictl
  hb_stop
  "$H/handoff.sh" > "$H/out/handoff.out" 2>&1 9>&-
  echo "$?" > "$H/out/handoff.rc"
  setstate ready
  beacon "${PREFIX}-ready" poll="$H/out/s4a-ready-poll.txt" \
    handoff="$H/out/handoff.out" handoff_rc="$H/out/handoff.rc"
  spawn_await
  ;;
ready)
  # A reboot of a ready node (the harness's own `reboot` verb, say). k3s comes
  # back on its own; only the waiter needs restarting.
  snap ready
  beacon "${PREFIX}-boot-ready" boot="$H/out/boot-ready.txt"
  spawn_await
  ;;
3)
  # The uninstaller was running when the machine went down. Not a path the page
  # describes, so it is recorded as a finding, and the confirmation still runs.
  snap 3
  beacon "${PREFIX}-finding-reboot-during-uninstall" boot="$H/out/boot-3.txt"
  confirm_and_finish
  ;;
3r)
  snap 3r
  beacon "${PREFIX}-boot-3r" boot="$H/out/boot-3r.txt"
  confirm_and_finish
  ;;
done)
  echo "run complete, nothing to do"
  ;;
*)
  echo "unknown state '$(state)'"
  beacon "${PREFIX}-finding-unknown-state" driver_log="$H/out/driver.log"
  ;;
esac
DRIVER
}

# ---- the heartbeat ---------------------------------------------------------
# The single thing run 1 lacked. Sixty seconds is short enough that a stuck
# `transactional-update` is visible while it is stuck. It overwrites ONE
# ConfigMap rather than minting one per tick, so an hour-long install leaves one
# object behind, not sixty; the tick number inside says how long it has run.
microos_heartbeat() {
  cat <<'HEARTBEAT'
#!/bin/bash
set -u
H=/var/lib/tockmox-harness
. "$H/env"
label="$1"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
i=0
while true; do
  i=$((i+1))
  {
    echo "heartbeat ${label} #${i} $(date -u +%FT%TZ)"
    echo "--- uptime ---"; uptime
    echo "--- ps ---"; ps -eo pid,stat,etime,cmd --sort=-etime | head -25
    echo "--- transactional-update ---"
    tail -40 /var/log/transactional-update.log 2>/dev/null || echo "(no log yet)"
    echo "--- step outputs so far ---"
    for f in "$H"/out/*.out "$H"/out/*.err; do
      [ -f "$f" ] || continue
      echo "### ${f##*/} ($(wc -c < "$f") bytes)"; tail -n 6 "$f"
    done
  } > "$H/out/heartbeat.txt" 2>&1
  "$H/beacon.sh" "${PREFIX}-heartbeat" hb="$H/out/heartbeat.txt"
  sleep 60
done
HEARTBEAT
}

# ---- the beacon ------------------------------------------------------------
# Write-only path out of the guest: one ConfigMap per call, labelled with the
# run. Every curl is time-bounded: an unbounded curl turns an unreachable
# apiserver into a hang, and a hang is the silence the heartbeat exists to
# remove. TLS is verified against the CA the harness's own kubeconfig trusts
# whenever the guest dials the same address; see `create`.
microos_beacon() {
  cat <<'BEACON'
#!/bin/bash
set -u
H=/var/lib/tockmox-harness
. "$H/env"
CM="$1"; shift
T="$(cat "$H/beacon.token")"
tls="-k"; [ -s "$H/beacon.ca.crt" ] && tls="--cacert $H/beacon.ca.crt"
tmp="$(mktemp)"
{
  printf '{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"%s","namespace":"%s","labels":{"tockmox.com/harness":"executed-docs","tockmox.com/profile":"microos","tockmox.com/run":"%s"}},"binaryData":{' \
    "$CM" "$BEACON_NS" "$PREFIX"
  f=1
  for p in "$@"; do
    k="${p%%=*}"; v="${p#*=}"
    if [ -f "$v" ]; then b="$(tail -c 100000 "$v" | base64 -w0)"; else b="$(printf 'no file %s' "$v" | base64 -w0)"; fi
    [ $f -eq 0 ] && printf ','
    f=0
    printf '"%s":"%s"' "$k" "$b"
  done
  printf '}}'
} > "$tmp"

post() {
  # shellcheck disable=SC2086
  curl -sS --max-time 25 -o /dev/null -w '%{http_code}' $tls \
    -H "Authorization: Bearer ${T}" -H 'Content-Type: application/json' \
    -X "$1" "$2" --data-binary "@${tmp}"
}

code=""
for try in 1 2 3 4 5 6 7 8 9 10; do
  code="$(post POST "${BEACON_API}/api/v1/namespaces/${BEACON_NS}/configmaps")"
  if [ "$code" = "409" ]; then
    code="$(post PUT "${BEACON_API}/api/v1/namespaces/${BEACON_NS}/configmaps/${CM}")"
  fi
  case "$code" in 201|200) break ;; esac
  # Early in a boot the route may not be up yet. Retry rather than drop the
  # report on the floor, which is how run 1 could have lost a phase silently.
  sleep 10
done
echo "$(date -u +%H:%M:%S) ${CM} http ${code} (try ${try})" >> "$H/out/beacon.log"
rm -f "$tmp"
BEACON
}

# ---- the kubeconfig handoff ------------------------------------------------
# The same contract as the Ubuntu lane's `secret` handoff, so `create`'s
# fetch_kubeconfig reads it unchanged: a Secret named ${PREFIX}-kubeconfig with
# `kubeconfig` and `ip` keys. Runs as root: it reads k3s.yaml, which is the
# harness's business rather than a documented step.
microos_handoff() {
  cat <<'HANDOFF'
#!/bin/bash
set -u
H=/var/lib/tockmox-harness
. "$H/env"
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
T="$(cat "$H/beacon.token")"
tls="-k"; [ -s "$H/beacon.ca.crt" ] && tls="--cacert $H/beacon.ca.crt"
IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
sed "s/127.0.0.1/${IP}/" /etc/rancher/k3s/k3s.yaml > /run/kc.yaml
B64="$(base64 -w0 < /run/kc.yaml)"
IPB64="$(printf '%s' "$IP" | base64 -w0)"
tmp="$(mktemp)"
printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s-kubeconfig","namespace":"%s","labels":{"tockmox.com/harness":"executed-docs","tockmox.com/run":"%s"}},"data":{"kubeconfig":"%s","ip":"%s"}}' \
  "$PREFIX" "$BEACON_NS" "$PREFIX" "$B64" "$IPB64" > "$tmp"
# 409 is NOT success (TM-0766): it means a stale ${PREFIX}-kubeconfig from an
# earlier guest is in the way, carrying that guest's credential. Replace it
# (PUT) and count only a 20x as delivered.
post() {
  # shellcheck disable=SC2086
  curl -sS --max-time 25 -o /dev/null -w '%{http_code}' $tls \
    -H "Authorization: Bearer ${T}" -H 'Content-Type: application/json' \
    -X "$1" "$2" --data-binary "@${tmp}"
}
code=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  code="$(post POST "${BEACON_API}/api/v1/namespaces/${BEACON_NS}/secrets")"
  if [ "$code" = "409" ]; then
    echo "handoff: ${PREFIX}-kubeconfig already exists (409), replacing it"
    code="$(post PUT "${BEACON_API}/api/v1/namespaces/${BEACON_NS}/secrets/${PREFIX}-kubeconfig")"
  fi
  case "$code" in 20*) break ;; esac
  sleep 10
done
shred -u "$tmp" /run/kc.yaml 2>/dev/null || rm -f "$tmp" /run/kc.yaml
echo "handoff ip=${IP} http=${code} tries=${i}"
case "$code" in 20*) exit 0 ;; *) exit 1 ;; esac
HANDOFF
}

# ---- the cloud-config ------------------------------------------------------
# Assembled by python rather than echoed line by line, and every file is
# carried base64-encoded. That is the Ubuntu lane's block-scalar lesson taken
# one step further: no byte of an extracted block, and no byte of a guest
# script, passes through a YAML scalar where it could be re-interpreted. What
# the guest executes is what the extraction wrote, byte for byte, which is the
# property PROVENANCE.tsv's fingerprints claim.
#
# Inputs arrive as MX_* environment variables so no value passes through a
# shell-quoted argv either. Writes the document to $1.
microos_cloud_config() {
  local out="$1"
  command -v python3 >/dev/null 2>&1 || { echo "REFUSING: the MicroOS profile needs python3" >&2; return 2; }
  local d; d="$(mktemp -d "${TMPDIR:-/tmp}/tockmox-mx.XXXXXX")"
  microos_env_file "$MX_PREFIX" "$MX_API" "$MX_NS" "$MX_USER" "${MX_READY_BUDGET:-900}" > "$d/env" || { rm -rf "$d"; return 2; }
  microos_driver    > "$d/driver.sh"
  microos_heartbeat > "$d/heartbeat.sh"
  microos_beacon    > "$d/beacon.sh"
  microos_handoff   > "$d/handoff.sh"
  printf '%s\n' "$MICROOS_TEARDOWN_SCAFFOLD" > "$d/teardown.SCAFFOLD.sh"
  printf '#!/bin/bash\nexec /var/lib/tockmox-harness/driver.sh per-boot\n' > "$d/perboot.sh"
  MX_SCRATCH="$d" python3 - "$out" <<'PY'
import base64, json, os, pathlib, sys

E = os.environ
H = "/var/lib/tockmox-harness"
scratch = pathlib.Path(E["MX_SCRATCH"])
ext = pathlib.Path(E["MX_OUTDIR"])

def wf(path, raw, perms="0755"):
    return {"path": path, "permissions": perms, "encoding": "b64",
            "content": base64.b64encode(raw).decode()}

files = []
blocks = sorted((ext / "blocks").glob("*.sh"))
if not blocks:
    sys.exit("REFUSING: no extracted blocks in %s" % ext)
for b in blocks:
    raw = b.read_bytes()
    if not raw.strip():
        sys.exit("REFUSING: block %s is empty; an empty block is never a pass" % b.name)
    files.append(wf("%s/blocks/%s" % (H, b.name), raw))
files.append(wf(H + "/PROVENANCE.tsv", (ext / "PROVENANCE.tsv").read_bytes(), "0644"))
for name in ("driver.sh", "heartbeat.sh", "beacon.sh", "handoff.sh", "teardown.SCAFFOLD.sh"):
    files.append(wf("%s/%s" % (H, name), (scratch / name).read_bytes()))
files.append(wf(H + "/env", (scratch / "env").read_bytes(), "0644"))
files.append(wf("/var/lib/cloud/scripts/per-boot/50-tockmox-harness.sh",
                (scratch / "perboot.sh").read_bytes()))
files.append({"path": H + "/beacon.token", "permissions": "0600", "encoding": "b64",
              "content": base64.b64encode(E["MX_TOKEN"].encode()).decode()})
files.append({"path": H + "/beacon.ca.crt", "permissions": "0644", "encoding": "b64",
              "content": E.get("MX_CA_B64", "")})

mirror = E.get("MX_MIRROR", "")
if mirror:
    # Scaffolding, and in /etc: see the header on /etc and snapshots. If the
    # documented reboot loses it, pulls fall back to upstream, which is the
    # mirror's own designed failure mode.
    lines = ["mirrors:"]
    for up in ("docker.io", "quay.io", "ghcr.io", "registry.k8s.io"):
        lines += ["  %s:" % up, "    endpoint:",
                  '      - "https://%s"' % mirror, '      - "https://%s"' % up]
    files.append(wf("/etc/rancher/k3s/registries.yaml", ("\n".join(lines) + "\n").encode(), "0600"))

cfg = {
    "hostname": E["MX_HOSTNAME"],
    # Narrate every cloud-init stage to the serial console, as the Ubuntu lane
    # does. logSerialConsole on the VM makes it readable from outside.
    "output": {"all": "| tee -a /dev/console"},
    "users": [{"name": E["MX_USER"], "sudo": "ALL=(ALL) NOPASSWD:ALL",
               "shell": "/bin/bash", "lock_passwd": True,
               "ssh_authorized_keys": [E["MX_PUBKEY"]]}],
    "ssh_pwauth": False,
    "write_files": files,
    # The driver is started by the per-boot hook above, not from here: runcmd
    # runs once, and this run has to cross a reboot. runcmd only makes the
    # output directory, and exists because a cloud-config with no runcmd is
    # refused by `create` as a document that would boot and do nothing.
    "runcmd": [["mkdir", "-p", H + "/out"]],
}
txt = "#cloud-config\n" + json.dumps(cfg, indent=1) + "\n"
pathlib.Path(sys.argv[1]).write_text(txt)
PY
  local rc=$?
  rm -rf "$d"
  return $rc
}

# ---- harness side: reading what the guest reported --------------------------
# Every beacon is a ConfigMap labelled with the run. This decodes them into
# DEST/<configmap>/<key>, which is the evidence as the guest wrote it ... not
# a summary of it.
microos_collect_evidence() {
  local ns="$1" prefix="$2" dest="$3"
  : "${TOCKMOX_SUBSTRATE_CONTEXT:?TOCKMOX_SUBSTRATE_CONTEXT is empty: the beacons are read from the hypervisor cluster}"
  mkdir -p "$dest"
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$ns" get configmap -l "tockmox.com/run=${prefix}" -o json 2>/dev/null \
    | python3 -c '
import base64, json, pathlib, sys
dest = pathlib.Path(sys.argv[1])
items = json.load(sys.stdin).get("items", [])
for cm in items:
    d = dest / cm["metadata"]["name"]
    d.mkdir(parents=True, exist_ok=True)
    for k, v in (cm.get("binaryData") or {}).items():
        (d / k).write_bytes(base64.b64decode(v))
    for k, v in (cm.get("data") or {}).items():
        (d / k).write_text(v)
print(len(items))
' "$dest"
}

# The newest non-heartbeat beacon for a run, for progress lines while waiting.
microos_latest_beacon() {
  local ns="$1" prefix="$2"
  : "${TOCKMOX_SUBSTRATE_CONTEXT:?TOCKMOX_SUBSTRATE_CONTEXT is empty: the beacons are read from the hypervisor cluster}"
  kubectl --context="$TOCKMOX_SUBSTRATE_CONTEXT" -n "$ns" get configmap -l "tockmox.com/run=${prefix}" \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null \
    | grep -v -- '-heartbeat$' | tail -1 | sed 's#^configmap/##'
}

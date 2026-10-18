---
okf_version: "0.2"
type: HowTo
title: "Time synchronisation for a disconnected site"
description: "Why every node's clock has to agree, how to point k3s nodes' chrony at an internal time source when nothing can reach a public pool, what drift looks like when it goes wrong, and the commands that verify it."
tags: [time, ntp, chrony, airgap, deployment, tls, etcd, troubleshooting]
status: stable
generated:
  by: hand
  at: 2026-09-29
tockmox:
  classification: public
  audience: [operator]
---

# Time synchronisation for a disconnected site

**Every node has to agree with every other node about what time it is. Being
right about the real time is a second, smaller requirement.** A connected site
gets both for free from public NTP pools. A disconnected one gets neither, the
symptoms of the gap never mention a clock, and the fix is small if it is done
before k3s installs and confusing if it is done after.

This is the long form of
[step 1 of installing with no internet access](airgap.md#1-point-every-node-at-a-lan-time-source--required),
which is the short procedure and is still the one to follow first. This page
adds the reasoning, the ways to build the source, what drift looks like, and a
verification set you can run again after any change.

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| Root or `sudo` on every node | You edit the time configuration and restart the daemon | `sudo -n true && echo ok` prints `ok` on each node |
| `chrony` on every node, or `systemd-timesyncd` | The steps below are written for `chrony`; the alternative is at the end of step 2 | `command -v chronyd` prints a path, or `systemctl is-enabled systemd-timesyncd` prints `enabled` |
| A time source that the nodes can reach over UDP 123 | Step 1 picks one; nothing after that works without it | `chronyd -Q -t 5 'server YOUR_TIME_SOURCE iburst'` reports an offset, run on a node |
| SSH from your workstation to every node | Step 3 compares the nodes to each other | `ssh YOUR_NODE_1 true` succeeds |

**Where each command runs.** Two places are involved, and every block says which:

| Marked | Runs on |
|---|---|
| **NODE** | A cluster node, over SSH or at its console. Every node, not one |
| **WORKSTATION** | Your machine, with `kubectl` and `ssh` |

## Why time matters

Kubernetes does not supply a clock. Time comes from the operating system below
it, each node has its own, and every component that compares a timestamp with a
clock of its own fails when the two disagree. The error messages rarely say so.

| What compares time | What drift does to it |
|---|---|
| TLS certificates, including those cert-manager issues from the private CA | A certificate carries a start and an end time. A node behind the issuing node sees a certificate that is "not yet valid"; a node far ahead sees one that has "expired". The Go error text includes the reader's own idea of the time (`current time ... is before ...`), which is the quickest way to tell a clock problem from a certificate problem |
| etcd, on a multi-server k3s | Raft leader elections and leases are timed on each member's clock. A single-server k3s keeps its state in SQLite and has no peer to disagree with, so this row applies to a high-availability control plane |
| cert-manager | Decides when a certificate needs renewing from its own clock, and stamps what it issues from its own clock. A wrong clock at issue time leaves a wrong validity window that outlives the fix |
| Bound service-account tokens | The API server checks a token's expiry against its clock; the kubelet decides when to refresh from its own. A node far off the API server's clock can hold a token the API server considers expired |
| Single sign-on (Authentik) and ArgoCD | OIDC and login tokens carry issued-at and expiry times, and time-based one-time passwords (TOTP) are computed from the server's clock. Sign-ins that loop, refuse, or reject a correct code are the classic presentation |
| Logs and metrics | Loki rejects entries too far in the past or the future; Prometheus drops samples it cannot order. Panels show gaps and Alloy logs the rejections. Correlating events across nodes by timestamp stops working before anything visibly breaks |
| Alerting | The self-check heartbeat computes its own expiry time from its node's clock (`charts/tockmox-selfcheck/templates/heartbeat.yaml`). A node clock more than the heartbeat's thirty-minute lifetime behind makes the heartbeat arrive already expired, and the stale-heartbeat alert fires for a reason that has nothing to do with Alertmanager |
| Schedules | Backup schedules, Longhorn recurring jobs and kured's reboot window all run on a node or controller clock. They fire at the wrong wall time, or, for point-in-time recovery, disagree with the database's own idea of the target time |

**None of that is a measurement made for this page.** It is what the
components do by design, read from their documentation and from this
repository's templates; the last two rows in particular are reasoned, not
observed. The one place this repository has direct evidence is the
[architecture note on time](../architecture.md#time-is-the-external-with-no-diagram-box-and-the-worst-symptoms),
which lists the four symptoms it has seen.

**The symptom worth memorising:** if TLS and single sign-on both misbehave at
once, check the clocks first.

## 1. Choose the time source ... Required

You need one source, or a small set that agree, that every node can reach and
that does not depend on the cluster. **Do not make the source a pod inside the
cluster:** the nodes need the time before k3s starts, so a source that only
exists once the cluster is up cannot bring the cluster up.

| Source | Good for | What it costs |
|---|---|---|
| The firewall or router (OPNsense and pfSense serve NTP; most enterprise firewalls do) | Most sites. It is already on the network, already reachable by every node, and already has to know the time | It needs an upstream to be right, and on a disconnected site it has none. Check what it does with no upstream (step below) |
| A NAS or a small always-on machine running `chronyd` | A site that wants the source to be a thing it owns | One more box to keep alive; put it on the same power as the nodes so they do not lose it and come back together |
| A GPS or GPS-with-PPS receiver on that machine | The only answer for a site that must be right about real time with no network at all | Hardware, an antenna with sky, and chrony reference-clock configuration that is outside this page |
| One node acting as the server for the others | A lab, when nothing else exists | The whole cluster now depends on that node's clock and on that node being up at boot. Acceptable for a lab, a poor trade beyond one |

**Agreement is the requirement; accuracy is the bonus.** A source with no
upstream and no receiver still gives every node the same time, which is all the
platform needs to work. What it cannot give you is the *right* time. That
matters when the site is compared with anything outside it: certificates you
present to external parties, log correlation with other systems, an auditor's
timeline. If that is you, plan the receiver, or a routine of setting the source
by hand against a trusted reference and re-checking it on a schedule.

**Check what your source does with no upstream.** Some daemons stop answering
when they lose their upstream, which turns a disconnected site's time source
into a silent failure. A `chronyd` configured to serve its own clock when it has
no upstream needs `local stratum 10` (see the server block below); a firewall's
setting for this is its own.

**Set the hardware clock to UTC** on every machine, in the BIOS or the
hypervisor, and set the OS to the same. A mixed site (some nodes with a local-time
hardware clock, some with UTC) is agreement broken by hand.

## 2. Point every node at it, and only at it ... Required

**Do this before k3s installs.** Certificates issued while a clock is wrong keep
their wrong dates after the clock is fixed; that is the reason for the ordering
and the reason it is cheaper than the repair.

**YOU SUPPLY:** the address of your time source. It is a value only you have, so
there is no default. Use an address inside your network; the documentation range
below is what the examples use.

**NODE** ... every node, before k3s:

```bash
export TIME_SOURCE=YOUR_TIME_SOURCE
test -n "$TIME_SOURCE" && test "$TIME_SOURCE" != "YOUR_TIME_SOURCE" && echo "source set: $TIME_SOURCE"
```

The line must print `source set:` and the address. If it prints nothing, the
placeholder is still there; stop and set it.

The configuration goes in a drop-in file, not in the distribution's main file,
so a package update does not overwrite it. The directory and the include line
differ between distributions. On openSUSE and Red Hat families the main file
includes `/etc/chrony.d/*.conf`; on Debian and Ubuntu it is
`/etc/chrony/conf.d/*.conf`. Check that the include exists before writing
there, because a drop-in nothing includes does nothing:

**NODE**

```bash
grep -E '^(confdir|include|sourcedir)' /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null
```

Then write the drop-in in the directory that answered (shown here as
`/etc/chrony.d`; use the other if that is yours):

**NODE**

```bash
: "${TIME_SOURCE:?export TIME_SOURCE first}"
sudo tee /etc/chrony.d/tockmox.conf >/dev/null <<EOF
server $TIME_SOURCE iburst
makestep 1.0 3
EOF
```

`iburst` makes the first synchronisation fast. `makestep 1.0 3` lets chrony
**step** the clock rather than slew it when the offset is over one second, but
only during the first three updates after it starts. That is what you want at
boot and not what you want on a running cluster, where a large step in the
middle of the day is itself an event.

**Now remove every other source.** A node still configured for a public pool on
an air-gapped network holds its drift silently forever: the pool never answers,
chrony keeps trying, and nothing complains. The stock configuration names a pool
on a `pool` line, and DHCP can add servers besides. Comment the pool line out
with the `!` chrony accepts for a comment, so the block pastes in either shell:

**NODE**

```bash
sudo sed -i 's|^pool |! pool |' /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null
sudo systemctl restart chronyd 2>/dev/null || sudo systemctl restart chrony
sudo chronyc makestep
```

The service is `chronyd` on the Red Hat and SUSE families and `chrony` on Debian
and Ubuntu; the line tries both. `chronyc makestep` steps the clock now if it is
off by more than the threshold, which is correct at this point in an install and
which you should think twice about on a running cluster.

**If a node should also serve time to the others** (a lab with no better
source), add this to that node's drop-in, with your own network in place of the
documentation range, and open UDP 123 to the nodes:

```
allow 192.0.2.0/24
local stratum 10
```

`local stratum 10` is what keeps it answering when it has no upstream, and
`allow` is what lets the others ask. Both are chrony directives, and neither
belongs on a node that is a client only.

**`systemd-timesyncd` instead of chrony.** It is a client only, it cannot serve
time, and it is less exact. For a single-server cluster that is fine. For a
high-availability control plane use chrony, because etcd is the component that
minds. If timesyncd is what you have, set `NTP=` to your source in a file under
`/etc/systemd/timesyncd.conf.d/`, and empty `FallbackNTP=` so it does not reach
for its built-in public list. Whether an empty `FallbackNTP=` clears that list
or restores it is not something this page has verified; step 3's
`timedatectl timesync-status` shows which server is actually in use, and that
is the test.

## 3. Verify, on every node and across nodes ... Required

**Success condition, on every node:**

**NODE**

```bash
chronyc tracking | grep -E 'Reference ID|Stratum|System time|Leap status'
chronyc sources -v
timedatectl show -p NTPSynchronized -p Timezone
date -u
```

- `Reference ID` names your source (an address or its name), not a public pool.
- `chronyc sources -v` lists your source and **no other**, with `^*` beside it
  (the `*` means it is the one currently synchronised to). A pool entry with a
  reach of `0` is a leftover that will never answer; remove it.
- `Leap status` is `Normal`, and `NTPSynchronized=yes`.
- `System time` is a small number of seconds fast or slow of the source.

`chronyc sourcestats` and `chronyc activity` show how many sources are online
and how stable the estimate is, and are the next commands to read if the above
looks wrong. `chronyc ntpdata` gives the raw packet timings for one source.

**Success condition, across nodes.** Compare the nodes to *each other*, not to
your watch. A whole site that is consistently wrong by an hour installs and runs
fine; a site whose nodes disagree internally does not. From your workstation
(the names are written out rather than kept in a list in a string, so the loop
behaves the same in both shells; add a line and a name per extra node):

**WORKSTATION**

```bash
export NODE_1=YOUR_NODE_1
export NODE_2=YOUR_NODE_2
export NODE_3=YOUR_NODE_3
for n in "$NODE_1" "$NODE_2" "$NODE_3"; do
  printf '%s ' "$n"
  ssh "$n" 'date -u +%s.%N'
done
```

The seconds column agrees to within a second or so across all nodes. The
fractions will not line up, because each `ssh` takes tens of milliseconds; this
comparison finds *seconds* of disagreement, which is the size that breaks TLS
and sign-in. The finer check is each node's own `System time` above.

**After the cluster is up**, one more check needs no shell on the node. The
observability layer renders two alerts for this, from the kube-prometheus-stack
node rules: `NodeClockSkewDetected` (a node's offset from its source beyond 0.05
seconds and not shrinking) and `NodeClockNotSynchronising` (the kernel reports
no sync and a large error bound for ten minutes). Confirm they exist in your
cluster:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first}"
kubectl --context "$KUBE_CONTEXT" get prometheusrules -A -o yaml | grep -c -E 'alert: NodeClock(SkewDetected|NotSynchronising)'
```

It prints `2`. **What those alerts do not cover:** both read a node's *own* view
of its offset from *its own* source. A node synchronised to the wrong source is
green. Two nodes each perfectly synchronised to different sources are green.
Neither compares nodes with one another, which is why the cross-node check above
is not optional and why nothing else replaces it.

## What drift looks like

Ordered by how early it shows, with the wording where this repository or the
upstream project fixes it. **None of these were reproduced for this page.**

| You see | It is usually | Check |
|---|---|---|
| `x509: certificate has expired or is not yet valid: current time ... is before ...` | A node behind the issuer, or a certificate issued by a node ahead | Compare the `current time` in the message with `date -u` on that node |
| Sign-in loops, "token expired" or "not yet valid", or a correct one-time code refused | The identity provider's clock and the verifier's clock apart | `date -u` on the node running Authentik and on the one running the client |
| `TockmoxSelfCheckStale` firing while the heartbeat Job completes and Alertmanager is healthy | The heartbeat's node clock behind its thirty-minute lifetime, so each beat arrives already expired | `date -u` on the node the heartbeat pod ran on |
| Loki or Alloy logs rejecting entries; gaps in Grafana; `out of order` from Prometheus | A node's timestamps outside what the store accepts | Compare that node's `date -u` with the store's |
| `NodeClockSkewDetected` or `NodeClockNotSynchronising` | The node has lost or never had its source | `chronyc sources -v` on it |
| etcd warning about clock difference with a peer, on a multi-server control plane | Two servers disagree | The cross-node check in step 3 |
| A Certificate that is `Ready` but rejected by clients | It was issued while a clock was wrong and its dates are wrong | Read the dates (below) |
| A backup or a reboot at an unexpected hour | The controller's node clock differs from the one you read the schedule against | `date -u` on the controller's node |

To read the dates on a certificate a service is presenting, and compare them
with the clock you trust:

**WORKSTATION**

```bash
export CHECK_HOST=YOUR_SERVICE_HOSTNAME
openssl s_client -connect "$CHECK_HOST:443" -servername "$CHECK_HOST" </dev/null 2>/dev/null | openssl x509 -noout -dates
date -u
```

`notBefore` later than `date -u` on your workstation means the issuer's clock
was ahead when it signed. That certificate stays wrong until it is reissued;
fixing the clock does not fix it.

## Recovering a running cluster

**Fix the source first, on every node, and confirm step 3 before touching
anything else.** Reissuing certificates against a clock that is still wrong just
mints new wrong ones.

Once the nodes agree:

- **Step the clock deliberately.** `sudo chronyc makestep` steps it now. A large
  step on a running node is an event: things that were mid-timeout will misfire
  once. Do one node at a time, and start with the ones that hold the least
  state.
- **Reissue what was issued while the clock was wrong.** The dates on the
  certificate (above) decide which. Deleting the Secret a Certificate points at
  makes cert-manager issue a fresh one, at the cost of a brief interruption for
  what uses it. That is an action for you to take, not a step this page runs.
- **Snapshot-restored and suspended virtual machines** resume with a stale clock
  and may take minutes to converge. Re-run step 3 after every restore. The
  [virtual machines page](virtual-machines.md#4-time-must-already-be-synchronised)
  has the check that goes with it.

## What is not certified here

**Executed:** nothing on this page has been run against a cluster or against a
node. The Prometheus alert names and thresholds in step 3 were read from the
rendered observability layer on 2026-09-29 (the two `alert:` lines exist in the
render); that they fire on a drifting node in a real cluster was not tried.

**Not measured:** every entry in the two tables of consequences. They describe
what the components do by design. The 0.05 second threshold is the upstream
alert's, and how much drift each component actually tolerates was not measured.
The heartbeat row is derived from reading the template, not from making a
heartbeat arrive expired.

**Not verified:** the drop-in and include paths for each distribution (the check
in step 2 exists because they were not confirmed), the `!` comment form against
a distribution's own `chrony.conf`, and the `systemd-timesyncd` fallback
behaviour. The reference platform this documentation was built against uses
chrony; nothing else was tried.

**Chosen, not derived:** advising against a pod-hosted or single-node time
source beyond a lab is a judgement about failure domains, not a measurement of
one.

## Next

- [Install with no internet access](airgap.md) ... the short procedure this page
  expands, and the rest of a disconnected install
- [Architecture § time is the external with no diagram box](../architecture.md#time-is-the-external-with-no-diagram-box-and-the-worst-symptoms)
  ... the four symptoms
- [Virtual machines § time must already be synchronised](virtual-machines.md#4-time-must-already-be-synchronised)
  ... the VM-specific trap
- [TLS and trust](../administration/tls-and-trust.md) ... the private CA whose
  certificates carry the dates this page is about

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

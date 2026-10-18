---
okf_version: "0.2"
type: HowTo
title: "Prepare a fresh cluster"
description: "The recommended path: build a three-node or single-node k3s cluster with the settings Tockmox expects, install ArgoCD and sealed-secrets, and decide the four values."
tags: [deployment, k3s, fresh-install, argocd, sealed-secrets, microos]
status: stable
generated:
  by: hand
  at: 2026-09-01
tockmox:
  classification: public
  audience: [operator]
---

# Prepare a fresh cluster

**This page makes the infrastructure choices for you** ... k3s, MetalLB,
Longhorn, and the exact flags Tockmox expects. What it cannot choose is the
handful of things only you know: your node OS, your API hostname, the chart
versions current on the day you read this, where your key backup lives, and the
four site values. Every one of those is marked **YOU SUPPLY** at the point you
need it, so you can scan for them before you start.

Everything else is a command to run in order.

**Already have a Kubernetes cluster?** Go to
[prepare a cluster you already have](existing-cluster.md) instead. That path has
checks rather than steps, because it cannot assume what is already running.

Both paths finish in the same place: [installation](install.md).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| **Three machines** (recommended) or **one**, 4 cores and 12 GB each at minimum, OS already installed | Step 3 decides which, and every command after it is labelled for one shape or both. 8 cores and 32 GB is comfortable; the full tiers are in [sizing](sizing.md) | `nproc && free -g` on each |
| Root or sudo on each | Package installs and the k3s server flags | `sudo -n true` |
| A workstation with `kubectl`, `helm` and `git` | `git` matters more than it looks: the installer writes a *site repository*, and without git you have a directory ArgoCD can never see | `kubectl version --client && helm version && git --version` |
| **On macOS: Local Network access granted to your terminal** | `kubectl` and `helm` are third-party binaries, and every workstation command on this page and in [install](install.md) targets a private address. Without the grant macOS refuses those connections and reports **`no route to host`**, which reads as a routing fault and is not one. Grant it now rather than at §6 | **System Settings, Privacy & Security, Local Network** ... enable your terminal application (Terminal, iTerm, Warp, or the editor whose integrated terminal is the parent), then **quit it fully (Cmd-Q) and reopen it**; the grant is read at process start. Details and the fallback at [§ 6](#6-install-argocd) |
| A clone of the Tockmox source tree | The last step here, and all of [install](install.md), run `./install/tockmox-install.sh` from its root | `ls install/tockmox-install.sh` |
| A LAN address range you can reserve | MetalLB hands these out. It must sit outside your DHCP scope | Your router's DHCP scope, read rather than remembered |
| An internal DNS zone you control, and the ability to add a **wildcard** record (`*.<your-zone>`) in it | Every console hostname lives under it, and the names must resolve **from inside the cluster**. One wildcard record is the default; per-host records are the alternative ([external integrations § DNS](../administration/external-integrations.md#dns-reference-unbound-on-the-firewall)) | `dig +short SOA <your-zone> @<your LAN resolver>` returns a record |

**Estimate, not a measurement: 60 to 90 minutes** for a single node, 2 to 3
hours for three, most of it package installs and waiting for nodes to join.

## Where each command runs

Two hosts are involved and the page switches between them constantly, which is
why the routing is stated **in the prose immediately above every block**, in
bold, rather than inside it. A marker inside a code block is stripped by every
"copy" control on every docs site, and it is the one piece of information that
decides which machine you are typing on. Counted against those markers:

- 33 blocks run on a node.
- 13 blocks run on your workstation.

Every block on this page is routed to one or the other; none is left for you to
guess at.

| Marked | Runs on |
|---|---|
| **NODE** | A cluster node, over SSH or at its console. On k3s use `sudo /usr/local/bin/k3s kubectl`, since plain `kubectl` is not on a node's PATH |
| **WORKSTATION** | Your own machine, against `$KUBE_CONTEXT` once step 4 has given you a kubeconfig |

**Why `sudo /usr/local/bin/k3s` and not `sudo k3s`.** The k3s installer puts its
binary in `/usr/local/bin`, and `sudo` does not necessarily put that directory
on the PATH it hands the command. openSUSE MicroOS is the concrete case, and it
is the operating system this page recommends: its vendor sudo configuration
lives at `/usr/etc/sudoers` rather than `/etc/sudoers` and sets `secure_path`
twice, the second of which omits `/usr/local/bin`. Later wins, so on a stock
node with a perfectly healthy cluster `sudo k3s` answers
`sudo: k3s: command not found`, at the first point this page asks you to verify
anything. Nothing local causes it and nothing local fixes it. That belongs to
the distribution rather than to k3s or to Tockmox, so every block on this page
spells the path out instead, which is true on every distribution. If you
installed k3s with `INSTALL_K3S_BIN_DIR` set, substitute that directory.

**No command block on this page contains a `#` comment line**, and CI enforces
it. macOS ships zsh as the default login shell and `INTERACTIVE_COMMENTS` is
off in an interactive zsh, so a pasted `# NODE` line returns
`zsh: command not found: #`. A trailing comment on a command line is worse,
because it fails quietly: `sudo systemctl restart k3s # k3s-agent on a worker`
passes `#` and `k3s-agent` and four more words to `systemctl` as arguments.
Everything those comments said is now beside the block rather than inside it.

## What you will have at the end

Either a **three-node cluster** (three etcd servers, surviving the loss of any
one node) or a **single node**, with storage packages present, k3s running with
the flags Tockmox expects, ArgoCD and sealed-secrets installed and pinned, and
four values written down.

**Optional, and shown as an example**: a fourth machine joined as a worker.
[Step 4d](#4d-optional-add-a-worker-node) is the pattern for every worker you
ever add, whether you run it now or a year from now. It is not part of the
recommended shape.

**You will deliberately end in two incomplete states**, both resolved during
[installation](install.md):

- **No LoadBalancer controller.** ServiceLB is disabled here and MetalLB arrives
  with Tockmox's wave-2 charts. Between the two there is none, and that is
  correct.
- **`local-path` still the default StorageClass**, and it stays that way.
  Tockmox names the class on every claim it creates and never takes your cluster
  default. Nothing here needs closing later.

## 1. Choose the node OS

**YOU SUPPLY:** which of these two you are running. It changes steps 2 and 4.

| Option | Choose it when |
|---|---|
| **openSUSE MicroOS** (recommended) | You want the platform Tockmox is developed and run on. Immutable, atomic updates, Btrfs snapshots, SELinux enforcing. Costs you a reboot per package change |
| A conventional distribution | You already run Debian, Ubuntu, RHEL, Rocky or SLES and want to keep one OS story. Everything below works; the package step differs |

**Verified on openSUSE MicroOS Tumbleweed with k3s v1.36.x, continuously
through 2026-09-01**, as the platform Tockmox is developed against: k3s with
SELinux enforcing, Longhorn on iSCSI, `transactional-update` plus kured for
node updates. That is a claim about the platform, not about this page ... see
[what is not certified here](#what-is-not-certified-here).

## 2. Install the storage packages, on every node

Longhorn needs an iSCSI initiator and an NFS client present **before** it
starts. Without `iscsiadm`, `longhorn-manager` fatal-crashes and volumes sit in
`attaching` behind a CSI error that names the volume rather than the missing
daemon.

**On openSUSE MicroOS:**

**NODE** ... every node

```bash
sudo transactional-update --non-interactive pkg install \
    open-iscsi nfs-client cryptsetup
sudo reboot
```

Then, **after the node has come back up**:

**NODE** ... every node, on MicroOS

```bash
sudo systemctl enable --now iscsid
```

Three things about that sequence:

- **`transactional-update` is atomic, and it fails quietly.** One unresolvable
  package name rolls the whole batch back with no obvious error. Add packages
  one at a time if you extend the list.
- **`--non-interactive` is required over SSH.** Without it the command waits on
  a prompt you cannot see.
- **The reboot is the install.** `transactional-update` builds a new snapshot;
  nothing changes on the running system until you boot into it. That is why
  `iscsid` is enabled *after* the reboot, not before.
- **MicroOS updates itself on a timer, and your `pkg install` can silently throw
  that update away.** `transactional-update.timer` ships **enabled**. Every
  `transactional-update` branches from the snapshot you are RUNNING, not from
  the pending one, so if the timer fires between your install and your reboot,
  whichever ran second wins and the other is discarded. Measured on openSUSE
  MicroOS 20260910, 2026-09-11: the timer ran at `00:55:06` and made snapshot
  #3; a `pkg install` at `00:56:32` made snapshot #4 from the same base; the
  node booted into #4 and #3's system update was gone.

  It does tell you, in a warning easy to read past:

  ```
  WARNING: This snapshot has been created from a different base (1)
           than the previous default snapshot (3) and does not
           contain the changes from the latter.
  ```

  **Disabling the timer is necessary and NOT sufficient, because it has usually
  already fired.** Measured on two fresh nodes, 2026-09-12: the timer ran about
  three minutes after boot, well before an operator finishes logging in, so a
  pending snapshot already exists by the time you get there. Disabling it stops
  the NEXT one and does nothing about that one.

  **So check first, and reboot to consume a pending update before you install
  anything of your own.** Expect exactly one snapshot newer than the one you
  are on:

  **NODE** ... every node, on MicroOS

  ```bash
  sudo snapper list
  ```

  The line marked `+` is what you will boot into and the line marked `-` is
  where you are now. **Two entries newer than the `-` line means one of them is
  about to be discarded** ... reboot, then re-run the install for whichever
  change did not survive.

  **`rebootmgr.service` is enabled too**, so a node can reboot itself at its
  maintenance window. That is correct for a running cluster and unhelpful
  halfway through an install. For a time-boxed build or a release gate, hold
  both off until you are done:

  **NODE** ... every node, on MicroOS

  ```bash
  sudo systemctl disable --now transactional-update.timer rebootmgr.service
  ```

  Re-enable them when the cluster is up; kured handles coordinated reboots from
  that point, and an unattended node that never updates is its own problem.

**On Debian or Ubuntu:**

**NODE** ... every node

```bash
sudo apt-get install -y open-iscsi nfs-common cryptsetup
sudo systemctl enable --now iscsid
```

**On RHEL or Rocky:**

**NODE** ... every node

```bash
sudo dnf install -y iscsi-initiator-utils nfs-utils cryptsetup
sudo systemctl enable --now iscsid
```

**On SLES or openSUSE Leap:**

**NODE** ... every node

```bash
sudo zypper install -y open-iscsi nfs-client cryptsetup
sudo systemctl enable --now iscsid
```

`cryptsetup` is only needed for Longhorn volume encryption. Install it anyway;
adding it later means touching every node again.

**Success condition**, on every node:

**NODE** ... every node

```bash
systemctl is-active iscsid && ls /usr/sbin/iscsiadm
```

Prints `active` and the path.

The path is spelled out for the same reason as `sudo /usr/local/bin/k3s` above:
`command -v iscsiadm` returns nothing for an unprivileged user on SUSE, because
`/sbin` and `/usr/sbin` are not on a non-root PATH there, and openSUSE MicroOS
is the first operating system this section lists. The system is correct when
that happens ... `open-iscsi` is installed, the binary is where the package put
it, and the consumer is the kubelet, which runs as root. A check that cannot go
green on a correct system teaches you to ignore checks.

## 3. Choose your cluster shape

**YOU SUPPLY:** how many nodes. This is the only branch on the page, and every
command below is labelled for one shape or both.

| Shape | Nodes | Choose it when |
|---|---|---|
| **Three** (recommended) | 3 servers | You intend to run this. Survives losing one node, and it is the point where replicated storage stops being decorative |
| **One** | 1 server | You are evaluating. Everything works; nothing survives the node |

**Two nodes is never right, and three is the floor for surviving anything.**
etcd holds quorum on a majority, so 3 members tolerate 1 loss and 2 members
tolerate none ... a two-node cluster is strictly worse than a one-node cluster,
because it has twice the hardware that can take it down.

**Three is the recommended shape, not a ceiling.** Everything past three is
capacity rather than resilience, and it is added the same way every time: as an
**agent**, never as a fourth etcd member. Four etcd members still tolerate only
one failure, because a majority of 4 is 3 ... you pay for a slower write path
and buy nothing. Keep etcd at 3 and add workers beside it.
[Step 4d](#4d-optional-add-a-worker-node) shows one, as the example of all of
them.

Skipping to one node now and adding nodes later is supported and is not free ...
Longhorn replica counts and
[the API endpoint](../administration/api-endpoint.md) both want revisiting, and
**`--cluster-init` is the one that cannot be retrofitted**: an existing sqlite
server has to be rebuilt to get embedded etcd. The other two are restarts. See
[sizing](sizing.md) for the four tiers.

**Weigh that against building one node first anyway, even when three is the
goal.** A multi-node cluster fails in more ways than a single node does, and
telling a genuine product defect apart from a joining problem is much easier
once you have watched the thing work on one machine. If you take that route,
plan on rebuilding node 1 rather than converting it.

### Before you install, on every node

Multi-node fails on these three long before it fails on anything Tockmox does:

**NODE** ... every node

```bash
hostnamectl
ip -4 addr show
timedatectl status
```

Read each one for a different thing: `hostnamectl` for a **unique** hostname per
node, `ip -4 addr show` for a static address or a DHCP reservation, and
`timedatectl status` for NTP synchronised.

etcd and TLS both fail badly on clock drift, and a node that changes address
mid-cluster is a bad first experience. Nodes must also reach each other on
**6443/TCP** (API), **2379-2380/TCP** (etcd, servers only), **8472/UDP** (flannel
VXLAN) and **10250/TCP** (kubelet).

## 4. Install k3s

### Set these on each node before you start

**Required, once per node, and it has to be once per node rather than once
overall.** These commands run on different machines, so a variable exported on
node 1 does not reach node 2 and none of them reach your workstation. Export
them at the start of your session on each node you are about to touch.

**YOU SUPPLY:** the API hostname. `K3S_VERSION` is pinned here rather than left
to whatever shipped this morning.

**NODE** ... every node, at the start of your session on it.

```bash
export K8S_API_NAME=YOUR_API_HOSTNAME
export K3S_VERSION=v1.36.4+k3s1
echo "api name: $K8S_API_NAME   k3s: $K3S_VERSION"
```

**`K8S_API_NAME` goes into the API server certificate**, so changing it later
means reissuing that certificate. **On three nodes use one name that will
outlive any single node** ... a DNS name you control, not a node's own
hostname.

**It is deliberately not a plausible-looking default.** Earlier versions of
this page wrote `tockmox.your.domain` directly into the command, which reads
like a value rather than like a blank: a reader can paste it verbatim, get a
cluster that installs and runs, and discover only much later that the API
certificate names a domain they do not own. A placeholder has to be obviously
not-a-value ...
[documentation standard § 5](../documentation-standard.md#5-commands-are-copy-pasteable-and-complete).

**Point that name at the first server for now if you like, but decide what it
will ultimately resolve to before you finish this page**, because it is also
the address your kubeconfig carries and therefore the thing that decides
whether losing one machine costs you `kubectl`. The three answers and their
costs are in [the API endpoint](../administration/api-endpoint.md).
**Deciding later is a rolling restart, not a rebuild** ... k3s regenerates the
serving certificate from the SANs it finds at start, so a name added to
`config.yaml` afterwards is picked up. Add every name and address you might use
to `--tls-san` now anyway; unused SANs cost nothing.

**About `K3S_VERSION`:** `v1.36.4+k3s1` is the version this platform claim was
measured against. An unpinned curl-pipe installs whatever shipped this morning.
A newer k3s is fine; record which one you used, and **use the same version on
every node** ... which is what exporting it once per node is for.

**Why the two `--disable` flags**, since neither is optional:

- `--disable traefik` ... Tockmox ships its own ingress, and the bundled one
  claims the same ports.
- `--disable servicelb` ... k3s's ServiceLB and Tockmox's MetalLB both watch
  `type: LoadBalancer` Services. Two controllers on that job is a race with a
  silent loser, and the failure surfaces as an unrelated component that cannot
  reach an address. Full anatomy in
  [load balancing](../administration/load-balancing.md).

**Why `--secrets-encryption`, and why at install time:** without it, every
Kubernetes Secret sits in the datastore in plaintext, and so does every copy of
the datastore ... including the etcd snapshots
[backup and restore](../operations/backup-restore.md) tells you to take and
ship off the cluster. Sealed-secrets protects secrets in git; this protects
them at rest and in every backup. It is set here rather than later because
enabling it on a running cluster is a multi-restart procedure with its own
failure modes, while at install it is one flag. `secretbox` (XSalsa20-Poly1305)
is chosen over the k3s default `aescbc`. The key material becomes part of the
cluster bootstrap data every server shares, but the flag itself is per server,
which is why it appears on the join command too. Confirm after install with
`sudo /usr/local/bin/k3s secrets-encrypt status` on a server: `Encryption Status: Enabled`.

### 4a. The first server ... BOTH SHAPES, on node 1

The only difference between the shapes is `--cluster-init`, which starts
embedded etcd instead of sqlite. **Multi-node clusters need it and cannot add it
afterwards without rebuilding.**

**Three nodes** ... **NODE 1**.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server --cluster-init \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**One node** ... **NODE 1**.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**On openSUSE MicroOS, use the block for your shape below instead.** Two extra
environment variables are required, and skipping them produces a k3s that
installs and will not start, with a `203/EXEC` error naming a permissions
problem rather than a labelling one.

They are **not** set on the blocks above on purpose: `INSTALL_K3S_SKIP_SELINUX_RPM`
is correct on MicroOS and wrong on RHEL or Rocky, where the `k3s-selinux` RPM is
exactly what you want installed.

**Three nodes, on openSUSE MicroOS** ... **NODE 1**.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  INSTALL_K3S_SELINUX_WARN=true \
  INSTALL_K3S_EXEC="server --cluster-init \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**One node, on openSUSE MicroOS** ... **NODE 1**.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  INSTALL_K3S_SELINUX_WARN=true \
  INSTALL_K3S_EXEC="server \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**On MicroOS, whichever of the two blocks above you ran ends in a failure on a
CORRECT install, and you continue anyway.** Its last lines read
`Job for k3s.service failed because the control process exited with error code.`
and it exits non-zero: 1, measured 2026-09-23 with the one-node block on
openSUSE MicroOS, and the three-node block runs the same installer the same
way. That is the `203/EXEC` described above, and the `restorecon` in the next
block is what fixes it: with the SELinux RPM skipped, the installer starts k3s
before anything has set its SELinux context. **Do not stop here.** Run the next
block; the success condition after it is what says whether the install worked.

If the `restorecon` in that block prints
`restorecon: open(/var/lib/rancher) failed: No such file or directory`, ignore
it. The installer stopped before it created that directory, the line is on
stderr, and the block still exits 0.

Then, after the installer finishes:

**NODE** ... every node, on MicroOS.

```bash
sudo restorecon -R /usr/local/bin/k3s /var/lib/rancher
sudo systemctl enable --now k3s
```

`k3s-selinux` resolves from the Tumbleweed OSS repository, so the installer's own
RPM step is skipped and the context is set by hand. Without the `restorecon`,
k3s fails to start with a `203/EXEC` error naming a permissions problem rather
than a labelling one.

**Success condition ... NODE 1:**

**NODE** ... 1

```bash
sudo /usr/local/bin/k3s kubectl get nodes
```

One node, `Ready`.

**If you chose ONE node, skip to [4e](#4e-finish-every-node--both-shapes).**
Steps 4b and 4c are multi-node only, and 4d is optional for everyone.

### 4b. Get the join token ... MULTI-NODE ONLY, on node 1

**NODE 1.** This prints the two values the other servers need.

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
ip -4 -o addr show scope global | awk '{print $2, $4}'
```

**YOU SUPPLY:** carry both to each joining node. They cannot be exported across
machines, so [4c](#4c-servers-two-and-three--multi-node-only) sets them again
on the node that needs them. Keep both ...
[4d](#4d-optional-add-a-worker-node) needs them again, and so does every worker
you add later.

### 4c. Servers two and three ... MULTI-NODE ONLY

Run this on node 2, wait for it to report `Ready`, then run it on node 3.
**One at a time.** Joining two at once against a fresh etcd is a good way to
spend an evening reading raft logs.

**NODE 2, then NODE 3** ... first the values from 4b, on the node you are
joining.

```bash
export NODE_1_IP=YOUR_NODE_1_IP
export NODE_TOKEN=YOUR_NODE_TOKEN
```

**NODE 2, then NODE 3** ... then the join itself. `K8S_API_NAME` and
`K3S_VERSION` come from
[set these on each node](#set-these-on-each-node-before-you-start), which you
run on this node too.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
: "${NODE_1_IP:?export NODE_1_IP first, see the block above}"
: "${NODE_TOKEN:?export NODE_TOKEN first, see the block above}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server \
    --server https://$NODE_1_IP:6443 \
    --token $NODE_TOKEN \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**On openSUSE MicroOS, use this join block instead.** It sets the same two
variables as the 4a MicroOS blocks, for the same reason, and it needs the same
values exported above.

**NODE 2, then NODE 3** ... on MicroOS.

```bash
: "${K8S_API_NAME:?export K8S_API_NAME first, see Set these on each node}"
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
: "${NODE_1_IP:?export NODE_1_IP first, see the block above}"
: "${NODE_TOKEN:?export NODE_TOKEN first, see the block above}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  INSTALL_K3S_SELINUX_WARN=true \
  INSTALL_K3S_EXEC="server \
    --server https://$NODE_1_IP:6443 \
    --token $NODE_TOKEN \
    --disable traefik \
    --disable servicelb \
    --secrets-encryption \
    --secrets-encryption-provider secretbox \
    --tls-san $K8S_API_NAME \
    --write-kubeconfig-mode 644" sh -
```

**On MicroOS, the join is not finished when the installer returns.** Run the
`restorecon` and `systemctl enable --now k3s` block from
[4a](#4a-the-first-server--both-shapes-on-node-1) ("every node, on MicroOS") on
this node now, before the success condition. Without the skip variables the
installer instead installs `k3s-selinux` through `transactional-update`, stages
a reboot, enables k3s and does not start it, so the success condition below
fails with `The connection to the server localhost:8080 was refused`. As in 4a,
the `restorecon` may print `open(/var/lib/rancher) failed`, which is harmless.

**Success condition**, after each:

**NODE 2, then NODE 3**

```bash
sudo /usr/local/bin/k3s kubectl get nodes
```

Every node so far `Ready`, with roles `control-plane,etcd`. Do not start
the next node until the previous one shows `Ready`.

**Three nodes `Ready` is the recommended shape, complete.** The required joining
is done. [4d](#4d-optional-add-a-worker-node) is optional; if you are not adding
a worker, go to [4e](#4e-finish-every-node--both-shapes).

### 4d. Optional: add a worker node

**Skip this and you have a complete cluster.** It is here because adding
capacity is the change most people make next, and this is the shape of it every
time ... one machine, one command, repeated per worker. Nothing later on this
page depends on having run it.

A worker joins as an **agent**, not a server. That is the whole point: it adds
capacity without touching etcd. A fourth etcd member would still tolerate only
one failure while making every write slower, so the control plane stays at
three however wide the cluster gets.

Run this on the new machine ... node 4 in the example, node 9 by the same
command. It needs [step 2's storage packages](#2-install-the-storage-packages-on-every-node)
first, like every other node:

**NODE** ... the new worker. Run
[set these on each node](#set-these-on-each-node-before-you-start) here first,
then the two values from [4b](#4b-get-the-join-token--multi-node-only-on-node-1).

```bash
export NODE_1_IP=YOUR_NODE_1_IP
export NODE_TOKEN=YOUR_NODE_TOKEN
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="https://$NODE_1_IP:6443" \
  K3S_TOKEN="$NODE_TOKEN" sh -
```

**On openSUSE MicroOS, use this block instead.**

**NODE** ... the new worker, on MicroOS.

```bash
export NODE_1_IP=YOUR_NODE_1_IP
export NODE_TOKEN=YOUR_NODE_TOKEN
: "${K3S_VERSION:?export K3S_VERSION first, see Set these on each node}"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_SKIP_SELINUX_RPM=true \
  INSTALL_K3S_SELINUX_WARN=true \
  K3S_URL="https://$NODE_1_IP:6443" \
  K3S_TOKEN="$NODE_TOKEN" sh -
```

A MicroOS worker's unit is `k3s-agent`, not `k3s`, and the installer leaves it
enabled but not running. The 4a MicroOS block names the wrong unit for a worker.
Run this on the worker instead:

**NODE** ... the new worker, on MicroOS.

```bash
sudo restorecon -R /usr/local/bin/k3s /var/lib/rancher
sudo systemctl enable --now k3s-agent
```

Skip this and the success condition below shows no row for the worker, with no
error anywhere. The `restorecon` may print `open(/var/lib/rancher) failed`,
which is harmless.

Two things that differ from a server join:

- **The `--disable` flags are not needed.** Traefik and ServiceLB are
  server-side settings; an agent runs neither.
- **`K3S_URL` and `K3S_TOKEN` replace `--server` and `--token`.** Setting
  `K3S_URL` is what makes the installer configure an agent at all. Pass
  `--server` instead and you get a fourth etcd member, which is the outcome this
  step exists to avoid.

**Success condition:**

**NODE** ... 1

```bash
sudo /usr/local/bin/k3s kubectl get nodes
```

Every node `Ready` ... the three servers showing `control-plane,etcd`,
and the worker you just added showing `<none>` in `ROLES`. **That `<none>` is
the assertion** ... a worker that joined as a server reads
`control-plane,etcd` here, brings etcd to four members, and looks exactly
like a success.

**Adding workers changes two things elsewhere**, and neither reports itself:
the service unit is `k3s-agent` rather than `k3s`, which
[4e](#4e-finish-every-node--both-shapes) needs, and a worker has no
`/var/lib/rancher/k3s/server/manifests` directory, so
[step 5](#5-stop-k3s-re-asserting-its-storageclass-default) does not apply to
it.

### 4e. Finish every node ... BOTH SHAPES

**Check mount propagation first.** The kubelet has to share the mounts it makes
with the CSI driver, or it cannot see the driver's socket and Longhorn does not
come up. Kubernetes calls this mount propagation, and Longhorn's own
requirement is that it works. Measure it rather than assume it:

**NODE** ... every node

```bash
findmnt -o TARGET,PROPAGATION /
```

- **`shared`:** nothing to do. systemd mounts `/` shared by default on openSUSE,
  and the reference lab runs k3s there with no drop-in at all and a healthy
  Longhorn. Skip to the success condition below.
- **`private` or `slave`:** the mounts k3s makes will not propagate. Add the
  `MountFlags=shared` drop-in below, which gives the service a shared mount
  namespace. Which distros land here is not something this page can list; the
  command above is the test.

`MountFlags=shared` is one way to get shared propagation, not the requirement
itself. On a node whose `/` is already shared it is redundant and harmless: the
reference lab applied it anyway, and `/` still read `shared` afterwards.

**Only if `/` is not shared.** On a worker, every `k3s` in a `systemctl`
command below is `k3s-agent` instead ... the unit name differs because an agent
runs a different service.

**NODE** ... every node that needs it

```bash
sudo systemctl edit k3s.service
```

Add exactly this, above the line reading `### Lines below this comment will be
discarded`:

```ini
[Service]
MountFlags=shared
```

Then:

**NODE** ... every node that needs it

```bash
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

**Success condition ... run on EVERY SERVER.** Four assertions, because a node
reporting `Ready` passes even when three of these are wrong. **On a worker, run
only the `findmnt` line and `systemctl is-active k3s-agent`** (the block after
this one), and read the worker's `Ready` from a server: a worker has no
kubeconfig, so the three `kubectl` lines fail there with
`localhost:8080 was refused` although the node is healthy.

**NODE** ... every server

```bash
sudo /usr/local/bin/k3s kubectl get nodes
findmnt -o TARGET,PROPAGATION /
sudo /usr/local/bin/k3s kubectl get pods -A | grep -Ei 'traefik|svclb' || echo "neither running: correct"
sudo /usr/local/bin/k3s kubectl version
```

Every node `Ready`; `/` reads `shared` on each; neither Traefik nor an `svclb-`
pod anywhere; the server version matches the one you pinned. **Propagation is
the one that matters most and fails silently** ... if `/` is not shared, the
node still goes `Ready` and Longhorn fails several pages later with an error
naming storage, not mount propagation. If you added the drop-in,
`systemctl show k3s -p MountFlags` reads `MountFlags=shared`; that shows the
setting took, and `findmnt` is what shows it worked.

**NODE** ... every worker

```bash
findmnt -o TARGET,PROPAGATION /
systemctl is-active k3s-agent
```

`/` reads `shared` and the unit reads `active`. Then read the worker's `Ready`
from a server with `sudo /usr/local/bin/k3s kubectl get nodes`.

### Then take the kubeconfig to your workstation ... BOTH SHAPES

**NODE**

```bash
sudo cat /etc/rancher/k3s/k3s.yaml
```

Save it to `~/.kube/config` on your workstation and replace `127.0.0.1` with an
address that reaches this cluster. **Everything after this step runs on the
WORKSTATION** unless marked otherwise:

**WORKSTATION**

```bash
kubectl get nodes
```

**Which address you put there is a real decision on a multi-node cluster, and
`--tls-san` already asked you half of it in step 4.** A node's own address works
and makes that one machine a single point of failure for your visibility: lose
it and `kubectl` stops, along with everything else that rides a kubeconfig,
while the cluster itself carries on fine. The three legitimate answers, what
each costs, and how to add one later without a rebuild are in
[the API endpoint](../administration/api-endpoint.md).

**Single node: use the node's address and move on.** There is nothing to fail
over to.

### Name the cluster, once, before anything writes to it

**Required, and it goes here** ... this is the first moment a kubeconfig
exists, and every workstation command from 4f onward reaches a cluster. By now
your kubeconfig may hold more than the one context you just built.

| What you need | Why | How to check |
|---|---|---|
| **Certainty about which cluster this is** | There is no undo on a controller install, and a context is a NAME you supply ... a rename can leave that name pointing at a different server than the one it used to | The block below prints the **server address**, not just a name you recognise. Confirm it is the cluster you built in step 4 |

**YOU SUPPLY:** the context for the cluster you built in step 4, once.

**WORKSTATION**

```bash
export KUBE_CONTEXT=YOUR_KUBE_CONTEXT
kubectl config view --minify --context="$KUBE_CONTEXT" \
  -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
```

Every block below that reaches a cluster starts with a guard line, so a block
pasted into a shell that has not run this one stops with a message instead of
running against whatever context happens to be current:

```
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
```

**A guard, not only the export.** `kubectl --context=` with an empty value does
not error ... it falls back to your current context. A shell variable used
directly, `--context="$KUBE_CONTEXT"` with no guard, therefore fails **open**
the moment the variable goes empty, silently, onto whatever cluster you last
touched. That happened live: a terminal restart (to pick up a privacy grant)
wiped the variable, and the next command addressed production. The guard turns
that same mistake into a stop rather than a silent install.

**Building this on a hypervisor?** [Virtual machines](virtual-machines.md) has
the four hypervisor settings that break Tockmox and the per-platform
walkthroughs. Read it **before** step 1 rather than after this one: a cloned VM
has to have its `machine-id` regenerated before it joins, and vSphere's
`disk.EnableUUID` needs a power cycle rather than a reboot.

### 4f. Prove the cluster survives a node loss ... MULTI-NODE ONLY

A three-server cluster that has never lost a server is an untested one, and the
cheapest moment to find out is now, while nothing is running on it.

**Two rules about which node you kill, and both change what the test proves:**

- **Kill a server, not a worker.** Losing a worker proves nothing about quorum,
  which is the property under test.
- **Unless your kubeconfig names something that outlives a node, do not kill the
  node it names.** Killing your own endpoint breaks `kubectl` on a cluster that
  is perfectly healthy, and the two outcomes look identical from your terminal.
  If you took a node's address in the previous step, pick a different server
  here.

Power off one **server** node, hard, from its power button or the hypervisor.
Not a graceful shutdown ... that tests something else.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get nodes
kubectl --context="$KUBE_CONTEXT" get pods -A -o wide | grep -v Running
```

The first command shows one node `NotReady` after roughly 40 seconds ... that
delay is the node-monitor grace period, not a slow command.

**Success condition:** every node except the one you killed stays `Ready` and
the API keeps answering. On the recommended three-node shape that is two nodes
still up: two of three etcd members is a majority, so the cluster holds. Power
it back on and confirm it rejoins before continuing.

**If the API stops answering, check these in order.** The first is far more
common than the second, and mistaking one for the other sends you to rebuild
nodes that are fine:

1. **Does your kubeconfig name the node you just killed?** Then this is not a
   cluster failure at all ... it is the single point of failure described in
   [the API endpoint](../administration/api-endpoint.md), doing exactly what it
   does. Confirm by running `sudo /usr/local/bin/k3s kubectl get nodes` **on a surviving
   server**: if that answers, the cluster is healthy and only your route to it
   is gone.
2. **Only if a surviving server also cannot answer**, you do not have three etcd
   members ... check that nodes 2 and 3 were joined with `server`, not as
   agents.

## 5. Stop k3s re-asserting its StorageClass default

Do this now, while `local-path` has just deployed and before Tockmox installs
Longhorn.

**NODE** ... every **server** (1, 2 and 3 on the recommended shape). **Not a
worker**: an agent has no server manifests directory, so this path does not
exist there.

```bash
sudo touch /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
```

k3s stops reconciling that addon and leaves the existing `local-path` class
exactly as it is ... which is what you want, because the storage policy and
`profiles/minimal.yaml` both need the class to keep existing. Without this file,
an un-default applied later is undone by the next k3s restart ... which only
matters if you choose to hand the cluster default to Longhorn, since a stock
install leaves your default alone.

k3s does not sync this file between servers, and a node rebuilt later needs it
again ... put it in whatever builds your nodes. The measurement and the
alternatives are in
[storage](../administration/storage.md#making-it-durable-skip-the-addon-then-patch).

**Multi-node: set the replica counts too.** With three storage nodes, Longhorn's
defaults stop being right ... one replica on one node protects against nothing,
and soft anti-affinity lets three replicas land on one host, silently removing
the property the extra nodes were bought for. Raise the counts to 3 **and turn
`replicaSoftAntiAffinity` off in the same change**. The keys and the reasoning
are in
[storage § Longhorn replica count](../administration/storage.md#longhorn-replica-count);
you set them in your site values during [installation](install.md).

**Success condition.** Two checks on two different hosts.

**NODE** ... every server (1, 2 and 3 on the recommended shape)

```bash
sudo ls /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
```

The `sudo` is not decoration. k3s creates `/var/lib/rancher/k3s/server` mode
`drwx------` owned by root, so an unprivileged `ls` returns **Permission
denied** whether or not the file is there ... which reads exactly like the
`touch` above having failed. Measured on a fresh k3s v1.36.4+k3s1 node,
2026-09-11.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get storageclass
```

The file exists on each server, and `local-path` is still listed and still
`(default)`. **It
stays default**, because Tockmox does not claim your cluster default. This step
is preparation for the case where you later choose to hand it to Longhorn with
`longhorn.persistence.defaultClass: true` ... cheap to do now, and impossible to
do retroactively without a restart. If you never make that choice, the `.skip`
file simply means k3s stops reconciling an addon it was going to keep
re-asserting anyway.

## 6. Install ArgoCD

**First, prove your workstation can actually reach the cluster.** Everything up
to here ran on a node. This is the first command on this page that goes from
your machine to the API, and a check that only prints client versions is green
at exactly the moment you are about to fail.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" get --raw /version
```

**Success condition:** it prints the server's version JSON. A client version is
not a substitute ... `kubectl version --client` deliberately never opens a
socket.

**If it fails with `no route to host`, read this before touching your network.**
`EHOSTUNREACH` from a Go binary against a private address, on macOS, is usually
not a network fault. It is the Local Network privacy gate refusing a
third-party binary, surfaced as a routing error. The shape that tells them
apart, and no network condition produces it:

| Call | Binary | Target | Under the gate |
|---|---|---|---|
| `helm show chart oci://registry-1.docker.io/...` | Homebrew, third-party | public | **works** |
| `kubectl get nodes`, `helm list` | Homebrew, third-party | private | `no route to host` |
| `curl -k https://<api>:6443/version` | Apple-signed | private | **answers**, `401` |
| `nc -vz <api> 6443` | Apple-signed | private | **open** |

The same binary reaching the public internet while failing to a private address,
with Apple-signed binaries reaching that same address fine, is the gate and
nothing else. Fix it in **System Settings, Privacy & Security, Local Network**.
Four things about that remedy are easy to get wrong, all written from the
2026-09-15 measurements recorded on TM-0625, not re-executed for this release:

1. **The grant attaches to the terminal application, not to the tool.** Enable
   the switch for the app your shell runs in. Re-signing `kubectl` or `helm`
   changes nothing, because macOS never looks at the binary when it decides
   whether the connection is allowed.
2. **"Restart" means a full quit.** Use Cmd-Q (or Quit from the menu) and open
   the app again. An application that relaunched itself after an update, or one
   whose window you closed while the process kept running, has not re-read the
   grant. If the switch is already on and the error persists, toggle it off, on,
   and then quit fully. That was the state that held for twenty-five minutes on
   the run this comes from.
3. **The first call after the grant lands can still fail.** Measured: in one
   pasted block, seconds apart, `kubectl get nodes` failed with `EHOSTUNREACH`
   and `kubectl get ns` succeeded. Run the check a second time before concluding
   the grant did not take.
4. **Apple-shipped binaries are exempt**, which is why the table above tells the
   two cases apart, and why `ssh` and `scp` keep working throughout.

**If the grant will not take, use the loopback route.** The gate covers
local-network addresses, and `127.0.0.1` is not one. Forward the API port
through an SSH connection and point `kubectl` at the forwarded address. The
forward is made by Apple-signed `ssh`, so the gate does not apply to it.
**YOU SUPPLY:** `USER` and `NODE_ADDRESS`, a login on a node that can reach the
API server. Run `ssh -N -L 6443:127.0.0.1:6443 USER@NODE_ADDRESS` and leave it
running, then in a second terminal point the cluster's `server:` in your
kubeconfig at `https://127.0.0.1:6443`. If `kubectl` then reports a certificate
name mismatch, the certificate does not list `127.0.0.1`; pass a name it does
carry with `--tls-server-name` rather than skipping verification. That last
point was not measured. This route is a bridge while you diagnose, not a
substitute for the grant.

On Linux this check simply passes, and a `no route to host` there is the network
fault it looks like.

ArgoCD cannot bootstrap itself and must not manage itself. Install it out of
band and leave it alone ... the reasoning is in
[ArgoCD](../administration/argocd.md#why-it-is-a-prerequisite).

**The CHART version and the ArgoCD APP version are different numbers.** The
block below prints both and then derives the newest chart version into
`ARGOCD_CHART_VERSION`. **It is derived and then shown to you, not substituted
silently** ... read the `appVersion` on the line it prints and confirm it is
`2.6` or newer before you install.

**WORKSTATION**

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo argo/argo-cd --versions | head -5
export ARGOCD_CHART_VERSION="$(helm search repo argo/argo-cd --versions \
  | awk 'NR==2 {print $2}')"
helm search repo argo/argo-cd --version "$ARGOCD_CHART_VERSION"
```

**Confirm before continuing:** the last line reprints the one chart version you
are about to install, with its `APP VERSION` beside it. If that `APP VERSION`
is older than `2.6`, set `ARGOCD_CHART_VERSION` by hand to a chart that carries
a newer one rather than continuing.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
: "${ARGOCD_CHART_VERSION:?run the block above first}"
helm install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --kube-context="$KUBE_CONTEXT" \
  --namespace argocd --create-namespace \
  --set controller.metrics.enabled=true \
  --set controller.metrics.serviceMonitor.enabled=false \
  --set server.metrics.enabled=true \
  --set server.metrics.serviceMonitor.enabled=false \
  --set repoServer.metrics.enabled=true \
  --set repoServer.metrics.serviceMonitor.enabled=false
kubectl --context="$KUBE_CONTEXT" -n argocd wait --for=condition=available \
  --timeout=300s deployment/argocd-server
```

**The six `--set` flags turn ArgoCD's metrics on at install time**, because the
chart ships all three metrics services disabled and ArgoCD is what reconciles
every layer of this product. They were added to this block at 0.6.1; before
that this page installed without them and asked for them three paragraphs
later, so a reader following it top to bottom needed a `helm upgrade` to
recover and the page never said so. The `serviceMonitor.enabled=false` half is
deliberate: Tockmox renders the ServiceMonitors itself, so they carry its
labels and land in the monitoring namespace with everything else. Full
reasoning, and the same values as YAML if you prefer a values file:
[ArgoCD § its metrics are off until you turn them on](../administration/argocd.md#its-metrics-are-off-until-you-turn-them-on).

**2.6 is a floor on the APP version, not the chart version.** The chart is
numbered independently and is well past 7.x; reading the chart number as the
ArgoCD version is the easy mistake here. The floor exists because the generated
Applications are multi-source and older ArgoCD cannot parse that.

**Success condition**, all three:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd wait --for=condition=available --timeout=300s \
  deployment/argocd-server
kubectl --context="$KUBE_CONTEXT" get crd applicationsets.argoproj.io
kubectl --context="$KUBE_CONTEXT" -n argocd get deployment argocd-server \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

The wait reports `condition met`, the CRD exists, and the image tag is `v2.6` or
newer. The third is the only one that actually proves the version floor.

### Create your site repository

**Do this now, before the token below**, because the token is scoped to a
repository that has to exist first ([history](#history-the-site-repository-step)).

On your own forge ... GitHub, Forgejo, GitLab, anything ArgoCD can reach ...
create **one empty repository**. Nothing in Tockmox creates it for you, and
nothing here needs it to be public.

| | |
|---|---|
| **Name** | Yours to choose. Something like `tockmox-site` reads well in ArgoCD's UI, where the repo URL is what identifies the source of every Application |
| **Visibility** | Private is fine and is the common case. Private is what makes the token below necessary; public needs no credential |
| **Contents** | **Empty.** No README, no `.gitignore`, no licence. The installer writes a complete tree and you push it in Phase 2; an auto-created README is a file you will have to merge around |
| **Branch** | The generated Applications target `main`. The forge's default does not matter for an empty repository; what matters is the branch **your** `git init` creates, which is why [install § 2a](install.md#2a-push-it) says `git init -b main` rather than a bare `git init` |

**You do not push anything yet.** The installer has not run. This exists now only
so that the token below has something to be scoped to.

### If your site repository will be private

**Mint a read-only access token for it now**, scoped to that one repository.
ArgoCD needs a credential before its first sync, not after the first failure:
without one, every Application goes to `Unknown` with a `ComparisonError` that
does not distinguish a missing credential from a wrong URL from a bad revision,
on all nine layers at once.

You apply it as a Secret during
[install § Phase 2](install.md#phase-2--publish-it), once you have the repository
URL. Shape and the three ways it goes wrong:
[ArgoCD § a missing repository credential](../administration/argocd.md#a-missing-repository-credential-names-nothing-useful).

**Success condition now:** you hold a token and it is read-only and scoped to
one repository.

**Confirm ArgoCD's metrics came up.** The install block above already turned
them on. Check it rather than assuming it, because this is half of a pair and
the other half is still yours to set.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n argocd get svc | grep metrics
```

Three services. A stock install, without those `--set` flags, lists none. If
you get none here, the flags did not reach the release: re-run the install block
as `helm upgrade` with the same flags.

> **This is half of a pair, and having only one half gets you neither**
> ([history](#history-the-argocd-metrics-pair)).
>
> The other half is `apps.argocdMonitoring`, which renders three ServiceMonitors,
> the ArgoCD dashboard **and** the sync-state alert rules together. It follows
> `capabilities.observability`, so it is on by default and you set nothing
> (TM-0739). This half alone gets metrics nobody scrapes; that half alone gets
> monitors scraping nothing.
>
> The release gate's **acceptance row N10** ("the ArgoCD dashboard renders
> panels rather than *No data*") depends on both, and there is no reminder
> between here and there.

## 7. Install sealed-secrets, with your own key

Sealed secrets are encrypted to your cluster's key, which is what makes it safe
to commit them.

**WORKSTATION.** Same shape as ArgoCD above: derived, then shown for
confirmation.

```bash
helm show chart oci://registry-1.docker.io/bitnamicharts/sealed-secrets \
  | grep -E '^(version|appVersion):'
export SEALED_SECRETS_CHART_VERSION="$(helm show chart \
  oci://registry-1.docker.io/bitnamicharts/sealed-secrets \
  | awk '/^version:/{print $2; exit}')"
echo "installing sealed-secrets chart $SEALED_SECRETS_CHART_VERSION"
```

**Confirm** the version echoed matches the `version:` line above it, then:

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
: "${SEALED_SECRETS_CHART_VERSION:?run the block above first}"
helm install sealed-secrets \
  oci://registry-1.docker.io/bitnamicharts/sealed-secrets \
  --version "$SEALED_SECRETS_CHART_VERSION" \
  --kube-context="$KUBE_CONTEXT" \
  --namespace kube-system
```

**Use the OCI reference.** Measured 2026-08-15, the other two published sources
are a 404 and a controller several releases back (0.31.0 against 0.38.4). This
controller holds the key every sealed secret in your repository is encrypted to.
Details in
[secrets](../administration/secrets.md#where-the-controller-chart-comes-from-and-why-it-matters).

**Success condition:**

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n kube-system get deployment sealed-secrets -o \
  jsonpath='{.status.readyReplicas}'
```

Prints `1`.

### Back up the controller's private key. Now.

Losing this key makes every sealed secret you have committed permanently
unreadable. Not inconvenient ... unreadable.

**YOU SUPPLY:** where the backup goes. It has to be somewhere this cluster's
failure does not reach ... a password manager, an encrypted volume, an
encrypted USB key in a drawer. Not the machine you are typing on.

**WORKSTATION**

```bash
: "${KUBE_CONTEXT:?export KUBE_CONTEXT first, see Name the cluster}"
kubectl --context="$KUBE_CONTEXT" -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-key-BACKUP.yaml

grep -c 'tls.key' sealed-secrets-key-BACKUP.yaml
```

**Success condition:** the count is at least 1, **and** you have moved the file
somewhere the cluster's failure does not reach. A backup in the working
directory of the laptop that built the cluster is not a backup. Off-network
copies, re-exporting after key renewal, and proving the backup restores are in
[secrets](../administration/secrets.md#back-up-the-controller-key-now).

## 8. Decide the four values

**YOU SUPPLY:** all four of these. Nothing can guess them.

These are values the charts cannot guess. The first two **fail the render** ...
the install stops with a schema error before anything reaches your cluster.

| You supply | Where it goes | If you skip it |
|---|---|---|
| Your LAN's CIDR | `global.lanCIDR` | The policy layer refuses to render |
| A free IP range for load-balancer addresses | `addressPool.range` | The platform layer refuses to render |
| An internal DNS zone | `global.internalDomain` | Nothing resolves; SSO fails at first login |
| Where the AI plane points, or nothing | see [the AI plane](../usage/ai-plane.md) | Open WebUI runs with no model behind it |

Two of these have a requirement that is easy to miss, and the DNS zone has a default worth taking:

- **The address range must sit inside `lanCIDR` and outside your DHCP scope.**
  Getting it wrong produces address conflicts that present as intermittent
  network faults, days later, on machines unrelated to the cluster. See
  [load balancing § the address pool](../administration/load-balancing.md#the-address-pool-needs-a-decision-before-you-start).
- **The DNS zone must resolve from inside the cluster**, not only from your
  workstation. SSO performs its token exchange server-side, so a workstation
  `/etc/hosts` entry is not enough: the console loads, the login starts, and the
  exchange fails with a DNS error. See
  [identity § DNS](../administration/identity.md#dns-one-requirement-worth-knowing).
- **The default is one wildcard record, `*.<internalDomain>`, at Traefik's
  address**, which you get at
  [install § point DNS at Traefik's address](install.md#point-dns-at-traefiks-address).
  It covers every console and every app added later, and the install's DNS check
  resolves a random label to prove it. Per-host records work too, one per
  hostname, and that check then fails by design;
  [external integrations § DNS](../administration/external-integrations.md#dns-reference-unbound-on-the-firewall)
  has both.

**The fourth is a three-way choice and "nothing" is a valid answer:** point the
AI plane at an inference host you already run, let Tockmox run models
in-cluster, or leave it unset and evaluate everything else first.

**Success condition:** you can write all four down. That is the whole test.

## What is not certified here

The platform claim above is about openSUSE MicroOS and k3s running Tockmox in
production. **It is not a claim that this page has been executed start to finish
as written.** Documented procedures are verified by running them, not by
reviewing them ... the [testing standard](../testing-standard.md) says which
paths are covered and which are not yet.

## History and corrections

What the steps above used to say, and when it changed. Nothing here is needed to finish the page.

<a id="history-the-site-repository-step"></a>

### The site repository step

Until 2026-09-12 this page asked you to mint a read-only token for a
repository whose creation was never a step on any page; it appeared only as an
aside much later, in `install.md` 2a. So the prerequisite arrived after the
step that needed it, and a reader either guessed or stalled (TM-0499). The
"Name the cluster" block also once sat between sections 5 and 6, after two
blocks that already needed it; a "before you begin" that appears after the
beginning is not one.

<a id="history-the-argocd-metrics-pair"></a>

### The ArgoCD metrics pair

"Turn on ArgoCD's metrics" was marked *Optional* until 2026-09-13 and
connected to nothing, so a reader who skipped it met an empty dashboard hours
later with no indication why (TM-0539).

Making it non-optional did not move it into the install command, so until
0.6.1 the page's order was: install ArgoCD, then three paragraphs later ask for
values that only apply at install time. Following the page top to bottom
produced an install without them and needed a `helm upgrade` the page never
mentioned. The values are in the install block now, and what remains here is a
check rather than a step (TM-0628). The lesson generalises past this pair: a
prerequisite that arrives after the command it is a prerequisite for is not a
documented step, it is a documented trap.

## Next

You have a prepared cluster. Continue at [installation](install.md), which
generates your site repository from the four values above, publishes it, mints
your credentials and applies the bootstrap.

The installer's `--dry-run` preflight, which reports exactly what it can and
cannot see, runs *after* you have written `tockmox.yaml` in
[install § Phase 1](install.md#phase-1--generate-your-site-repository). It is on
that page rather than this one because it needs a file that does not exist yet.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.1 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

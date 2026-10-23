---
okf_version: "0.2"
type: HowTo
title: "AI nodes"
description: "Turn an Apple-silicon Mac into an inference node that converges itself from your site repository: accounts, firewall, engines, pinned models, telemetry and its own updates, with no agent that accepts commands."
tags: [ai-plane, inference, macos, mlx, ollama, llama-server, gitops, ansible, experimental]
status: draft
generated:
  by: hand
  at: 2026-10-21
tockmox:
  classification: public
  audience: [operator]
---

# AI nodes

[Inference nodes](inference-nodes.md) tells the model gateway where a machine is
and which models it serves. This page is about the machine. The `ai-node/`
toolkit makes a Mac that serves models describe itself in git, converge to that
description every fifteen minutes, and say whether it is ready.

> **Experimental, macOS only.** The playbook, its roles and the converger have
> been linted, unit-tested and run end to end on Linux against stand-ins for the
> macOS tools. They have not run on a Mac. [What is not certified
> here](#what-is-not-certified-here) lists every claim that waits for one, with
> the command that settles it. A Linux node stops with a message that says Linux
> support is not built yet.

## What you get

- Two accounts: `tockmox`, an administrator that runs the converger, and
  `inference`, a hidden standard user that runs every engine and exporter.
- A pf allowlist that closes the engine, exporter and administration ports to
  everything except the networks you name, loaded before any engine binds a
  non-loopback address, with a timed rollback for the change that could lock
  you out. Every engine and exporter starts through a wrapper that waits until
  the allowlist is in force for the current boot.
- Engines from one pinned set: mlx-lm in a pinned virtualenv, llama-server from
  Homebrew, and Ollama from Homebrew, each as a LaunchDaemon.
- Models fetched at an exact Hugging Face commit or an exact Ollama manifest
  digest, verified on disk, retained for a grace period after they leave the
  list, and written to an audit log.
- node_exporter and macmon for Prometheus, plus a readiness textfile
  (`tockmox_ai_node_readiness`) that reads FileVault, the firewall, the wired
  GPU memory limit and the rest of the posture from the machine.
- Headless-machine settings: no sleep, restart after power loss, Spotlight, Time
  Machine, analytics and the assistant off, automatic OS install off, the GPU
  wired-memory limit set at every boot.
- A converge that runs at boot and every fifteen minutes, and a metrics file
  that says when it last succeeded.

It does not give you a command channel. No process on the node accepts a
request. The node pulls from git, checks signatures against keys it pinned
itself, and applies. The only way to change it is a commit.

## How the pieces fit

Three places hold everything:

| Place | Holds | Written by |
|---|---|---|
| Your site repository, under `ai-nodes/` | Per-node intent, the signers, the encrypted secrets | You, and the renderer |
| The toolkit, `ai-node/` in the Tockmox repository, at the ref a verified `fleet.yaml` pins | The playbook, the roles, the converger | A Tockmox release |
| The node, under `/opt/tockmox` | A clone of each, the keys the node made, its state | The node |

The site layout:

```text
ai-nodes/
  fleet.yaml                  toolkit repo and ref, converge interval, signing mode
  allowed_signers             who may sign commits (git's allowed-signers format)
  gpg-signers.asc             optional: the forge's merge-signing key
  .sops.yaml                  who can decrypt each node's secrets
  example-mac/
    ai-node.yaml              authored: the machine's posture and engine versions
    desired.yaml              generated: instances, models, ports, firewall
    secrets.sops.yaml         optional: encrypted API keys
site/values/models.yaml       the inference nodes and the model lifecycle
```

`desired.yaml` is produced by the renderer from `site/values/models.yaml` and
`ai-node.yaml`. Which engines run and which models they serve is decided there,
once, and the same file tells the gateway where to send traffic. Nothing under
`ai-nodes/` belongs in an Argo CD application path.

A converge has five phases, and the metrics say which one failed:

1. **fetch** the site at its ref, then the toolkit at the ref the site pins;
2. **verify** every commit since the last verified one against the signers pinned
   on the node, before anything from the new head is read;
3. **decrypt** `secrets.sops.yaml` with the node's own age key;
4. **load** the playbook and the node's two files;
5. **run** the playbook against `localhost`.

## Before you start

Some things cannot be done from git because they are needed to reach the Mac at
all, or because macOS asks a person. At the console:

1. Finish Setup Assistant and create the administrator you will bootstrap
   from. Skip the Apple Account, or sign out of it afterwards; the readiness
   textfile reports whether an Apple Account is signed in.
2. Turn on Remote Login (System Settings, General, Sharing). The toolkit
   asserts it is on and fails the converge when it is not. It does not turn it
   on.
   Then put your public key in the administrator's `~/.ssh/authorized_keys`
   (`ssh-copy-id admin@mac.example.com` from the machine you administer it
   from). The toolkit turns password and keyboard-interactive logins off only
   once it finds a key there, so a node without one keeps password logins and
   says so in the converge log.
3. Apply pending macOS updates. The toolkit turns automatic installation off and
   reports the build it sees; a node that updates itself overnight is a node
   that restarts under load.
4. Turn on starting up automatically after a power failure. The toolkit also
   sets the equivalent `pmset` value, and the console switch is the one that
   survives a reset.
5. Decide FileVault. `os.filevault: "off"` (the default) suits a machine on a UPS
   that must come back by itself. `"on_ssh_unlock"` needs a person to unlock the
   disk over SSH after every restart. The toolkit reports the posture and does
   not change it.
6. Give the Mac a fixed address, and put the networks that may administer it in
   `access.adminCidrs`. The list must not be empty and must not contain a
   `/0`; the firewall will not load a rule set that could lock every
   administrator out or admit the world.

In your site repository, commit before you bootstrap: `ai-nodes/fleet.yaml`,
`ai-nodes/allowed_signers`, and the node's directory with `ai-node.yaml` and the
rendered `desired.yaml`. [`ai-node/examples/`](https://github.com/tockmox/tockmox/tree/main/ai-node/examples)
holds a complete generic slice to copy.

Set `signing.mode: warn` in `fleet.yaml` for the first nodes. In `warn` an
unsigned or unverifiable commit is applied anyway and the node reports
`tockmox_ai_node_converge_signature_ok 0`. Move to `enforce` once the signers are
right; a fleet file can tighten a node's mode and never loosen it.

## Bootstrap

**WORKSTATION**

Copy the script to the Mac and run it from a terminal, because it stops to ask
you things:

```bash
scp ai-node/bootstrap-node.sh admin@mac.example.com:/tmp/
ssh -t admin@mac.example.com 'bash /tmp/bootstrap-node.sh --ai-node-id example-mac --site-repo git@git.example.com:org/site.git'
```

Add `--dry-run` first to see every action without any change. The script is safe
to run again: a step that is done says so and moves on.

What it does, in order, and where it stops:

1. Checks it is on Apple silicon at or above the OS floor, and that both
   repositories answer.
2. Creates `tockmox` and `inference` with `sysadminctl`, hides `inference`, and
   gives it no login shell.
3. Installs Homebrew as you, hands it to `tockmox`, and installs `ansible`,
   `git`, `sops`, `age` and `gnupg`.
4. Builds the `/opt/tockmox` tree with the owners and modes the roles expect and
   seeds the sudoers fragment the converge job needs.
5. Makes a deploy key and an age key **on the node**. It prints the public
   halves and their fingerprints. The private halves are never printed, logged
   or sent anywhere.
6. **Stops.** Register the deploy key on the site repository as read-only, add
   the age recipient to `ai-nodes/.sops.yaml`, re-key the node's secrets file if
   it has one, commit, and press Return.
7. Fetches the site host's SSH key, shows its fingerprints, and pins it only if
   you type `yes`. Compare the fingerprints with what the forge publishes; a
   scan over the network proves nothing by itself.
8. Clones the site and the toolkit, and tries a push with `--dry-run`. If the
   deploy key can write, the script stops: a node that can change its own
   configuration defeats the signing.
9. Shows the signers in `ai-nodes/allowed_signers` with their fingerprints and
   pins them in `/opt/tockmox/etc` only if you type `yes`. This is the trust
   anchor. Later commits are checked against what you pinned here, and a commit
   can change the signer set only if an already-pinned key signed it.
10. Writes `/opt/tockmox/etc/ai-node.env` (no secrets in it) and runs the first
    converge with you watching.

The first converge loads the firewall. If it changes who may administer the
node, it arms a five-minute rollback and then waits for evidence that an
administrator can still get in: an established SSH session from an admin
network, or `tockmox-ai-node-converge --confirm-firewall` run by you. With
neither, the converge fails and the rollback fires. The rollback never leaves
the anchor empty: it puts back the last ruleset an administrator confirmed, or,
on a node that never had one, a minimal ruleset (loopback, the administration
ports from anywhere, the engine and exporter ports blocked). From-scratch, that
minimal ruleset admits port 22 from any source by design: it exists to keep a node
reachable, not to narrow who may reach it, and the next verified converge replaces
it with the allowlist. Stay connected over
SSH during the first run and the session you are in is the evidence.

## What a converge does

The roles run in this order. The firewall is first, and nothing opens a
non-loopback port until it is verified:

| Role | Does |
|---|---|
| `ai_node_assert` | Refuses a bad machine, a bad `adminCidrs`, a wired limit outside its bounds, a Linux node |
| `firewall` | Renders and loads the pf allowlist into a sub-anchor, with the rollback |
| `macos_accounts` | Checks both accounts, hides the service account, owns the tree |
| `homebrew_baseline` | Installs the baseline packages |
| `macos_remote_access` | Asserts Remote Login, limits who may log in over SSH |
| `macos_base` | Sleep, restart after power loss, the open-file limit, caffeinate |
| `macos_strip` | Spotlight, Time Machine, analytics and the assistant off |
| `macos_updates` | Automatic install off, records the OS build |
| `gpu_memory` | Sets `iogpu.wired_limit_mb` live and at every boot |
| `exporters` | node_exporter and macmon |
| `engine_ollama`, `model_sync`, `engine_mlx_lm`, `engine_llama_server` | Engines and the models they serve |
| `converge_timer` | Installs the converger, the facts writer and their LaunchDaemons |

Engines and exporters bind `127.0.0.1` until the firewall is verified in force
on that run, and `0.0.0.0` after. A run with `--tags` verifies the firewall
itself first.

The bind address is not the only guard. Each engine and exporter (macmon
included) is started by `/usr/local/libexec/tockmox-ai-node/start-when-firewalled`,
a root-owned wrapper that waits for the file
`/var/db/tockmox-ai-node/pf-boot-ok` and then execs the program. The pf loader
deletes that file as its first action, loads the sub-anchor, and writes the file
again only after `pfctl -a com.apple/250.tockmox -sr` shows the block rule. The
file holds the `kern.boottime` of the current boot, so after a restart, or a pf
reset, a listener on `0.0.0.0` does not exist until the allowlist is back, and if
the allowlist never loads it never starts. A converge that finds no block rule in
force (pf off, or the sub-anchor empty or gone) deletes the file and boots out
every engine and exporter before it fails, also when the play failed before it
reached the firewall role. The test is "a ruleset with the managed-port block is
live", not "the newest rules are live": after a rollback the last confirmed rules
still protect the engines, so a refused change does not turn into an outage.
`firewall_block_in_force` therefore means "a block rule is live in the anchor",
and only a rendered, last-confirmed or minimal ruleset can put one there.
Running engines are not touched while the block is in force. Nothing re-checks pf between
converges, so a sub-anchor flushed by hand is noticed at the next converge, up to
`convergeIntervalSeconds` later (900 by default), and until then an engine that
restarts finds the marker still valid. The first converge
after upgrading to a toolkit that has the wrapper rewrites each plist once, and
so restarts each engine once.

Log files are created by root, in `/opt/tockmox/log`, which the converge account
owns and the service account cannot write to; each file is then handed to the
account that writes it. `textfile` and `var/audit` stay group-writable because
the facts writer and the model helper write into them as the service account, and
nothing running as root writes there.

A model that is not on disk is not started, and a pinned model that does not
match its pin is removed and fails the converge. The check is the blob name for a
Hugging Face file (the cache names each blob by its hash) and the manifest's
sha256 for Ollama. A file Hugging Face stores with its Xet backend is cached under
its Xet hash instead, which is not the SHA-256 of the content; for such a file the
node reads the Hub's record of it at the pinned commit and requires the blob's name
to be the listed Xet hash and the content to hash to the listed SHA-256. If the Hub
cannot be reached the model is refused, not trusted.

## Signatures and the history they cover

On every run the node verifies each commit on the first-parent chain from the
last verified commit to the new head. An ssh signature is checked against the
pinned `allowed_signers`; a GPG signature against the pinned `gpg-signers.asc`
(GitHub's merge commits are GPG-signed by the forge, so a site that merges on the
forge needs both). A history that was rewritten under the last verified commit
is refused in `enforce` and reported in `warn`.

Two limits belong to the design and are worth knowing before you choose keys.

- **One pinned signing key can rotate the whole signer set.** A commit that
  changes `ai-nodes/allowed_signers` is accepted when any key already pinned
  signed it. Whoever holds one signing key can therefore replace every other
  signer with their own and, from then on, sign anything: losing one key is the
  full loss of the trust root, not a one-key problem. Keep the list short, keep
  the keys on hardware, and after a loss replace `/opt/tockmox/etc/allowed_signers`
  on the node by hand instead of rotating through git.
- **`warn` applies what it cannot verify.** In `warn` an unverified head is still
  applied: its `ai-node.yaml`, `desired.yaml` and secrets file take effect, and
  with them the engine arguments they carry. What cannot come from an unverified
  head is the code that interprets them. See the next section.

### Which toolkit runs

The playbook runs as root, so nothing in the site repository chooses it freely.

- The toolkit **repository** is pinned on the node (`TOOLKIT_REPO` in
  `/opt/tockmox/etc/ai-node.env`, written at bootstrap). A `toolkit.repo` in
  `ai-nodes/fleet.yaml` that names a different repository is refused in both
  modes, signed or not, with exit code 11. To move the toolkit to another
  repository, change the pin on the node.
- The toolkit **ref** is taken from `toolkit.ref` in `fleet.yaml` only when the
  head's signatures verified. Otherwise the node keeps the last ref a verified
  head chose (`verified_toolkit_ref` in `var/state.json`), and before there is
  one, `TOOLKIT_REF` from `ai-node.env`. In `warn` that means an unsigned commit
  can change the desired state but not the toolkit; in `enforce` it is refused
  outright.
- A ref that is a branch **follows pushes**: whoever can push to that branch of
  the toolkit repository gets root on every node that tracks it, on the next
  converge. For production pin a tag, or better a 40-hex commit. Only a 40-hex
  commit is immutable, and it is the only form the node checks resolves to
  exactly what was named; a tag can be moved by anyone who can push tags.

The converger reads these values from the checked-out head: the signing mode (only
from a verified head, and it can only tighten), `toolkit.repo` (compared with the
pin, never used), `toolkit.ref` (verified head only), `defaults.convergeIntervalSeconds`
(accepted only as a whole number of at least 60), `labels.prefix` and
`accounts.service` from `ai-node.yaml`, and the files handed to the playbook. None of
them is a path or a command.

### The site files are data

`ai-node.yaml` and `desired.yaml` reach the playbook as one extra variable,
`tn_site`, with the two files under `tn_site.ai_node` and `tn_site.desired`. They
are never top-level variables. Extra variables outrank every role default and play
variable, so a top-level key such as `gpu_memory_sysctl` or `firewall_pfctl` in a
site file would otherwise choose a program that root runs. Under the namespace such a
key is only an unknown key, and no role reads a variable from site content except
through the namespace. The converger writes the namespaced file itself, and marks it
`!unsafe`, so a value like `{{ lookup('pipe', 'id') }}` stays literal text instead of
being evaluated as a template.

The first task of the first role, `ai_node_assert`, checks both files against
`ai-node/schema/ai-node.v1.schema.json` and `desired.v1.schema.json` from the toolkit
checkout: types, enums, patterns, required keys and, at every depth, no key the
schema does not name. The check runs on the node, with the standard library only, on
every run including `--tags` runs, and a file that fails it stops the converge before
the firewall, any account or any engine is touched. The facts writer, which runs even
after a failure, writes nothing as root until the check has passed. In `warn` mode an
unsigned commit can still change any value the schema allows, such as an engine's
arguments or environment; it cannot add a key or change a type.

One consequence of the types being enforced: an unquoted `off` in YAML is a boolean,
so `os.filevault: off` is refused with the message `must be one of`. Quote it
(`"off"`).

If you must accept history you did not sign, for example after moving the site to
a new repository, trust it explicitly:

**NODE**

```bash
sudo -u tockmox /opt/tockmox/bin/tockmox-ai-node-converge --rebaseline COMMIT
```

It shows the commit and asks you to type `yes`.

## Secrets

`ai-nodes/<id>/secrets.sops.yaml` holds API keys encrypted to the administrators'
age keys and the node's own recipient. Its decrypted shape:

```yaml
secrets:
  - name: example-llama-key
    owner: service
    value: replace-with-a-long-random-string
  - name: hf-token
    owner: converge
    value: replace-with-a-token
```

Each secret is written to `/opt/tockmox/secrets/<name>` at mode 0600, owned by the
service account (`owner: service`) or the converge account. A secret removed from
git is removed from the node. A secret a name refers to (`auth.secretRef`) must
exist before the engine that wants it starts. Only llama-server reads
`secretRef` today, through `--api-key-file`. The token the converge uses to fetch
gated Hugging Face models is the secret named `hf-token`.

## Reading the node

**NODE**

```bash
cat /opt/tockmox/textfile/converge.prom
cat /opt/tockmox/textfile/facts.prom
sudo -u tockmox /opt/tockmox/bin/tockmox-ai-node-converge --check --diff
```

The last command changes nothing and shows what a converge would change.

| Series | Meaning |
|---|---|
| `tockmox_ai_node_converge_last_success_timestamp_seconds` | Alert when it is older than a few intervals |
| `tockmox_ai_node_converge_last_exit_code` and `_phase{phase=...}` | What failed, and in which phase |
| `tockmox_ai_node_converge_tasks{state=...}` | The recap; `failed` is -1 when the play never loaded |
| `tockmox_ai_node_converge_signature_ok` | 1 when every new commit verified |
| `tockmox_ai_node_readiness{check=...}` | 1 holds, 0 does not, absent is unknown |
| `tockmox_ai_node_model_present` | A pinned model revision that is on disk |

Absent means unknown and nothing downstream should read it as healthy. The
facts writer runs as the unprivileged service account; the few facts only root can
read are written by the converge each run and ignored once they are stale.

## Adopting a node that already serves

A node with a working converger, a different label prefix or engines already
running can be taken over without a restart:

**WORKSTATION**

```bash
ssh -t admin@mac.example.com 'bash /tmp/bootstrap-node.sh --ai-node-id example-mac --site-repo git@git.example.com:org/site.git --adopt --legacy-converger-label com.example.old-converger'
```

`--adopt` installs no converge timer, writes the LaunchDaemon files without
restarting a running engine, and makes the first converge a `--check --diff`
preview you read before confirming. Set `labels.prefix` in `ai-node.yaml` to the
prefix the old services use, and `legacy:` to name its root and service account.

Two convergers must never run at once, so an applying converge refuses while any
LaunchDaemon other than its own runs `ansible-pull` or is named in
`LEGACY_CONVERGER_LABELS`. Retire the old converger first. Then remove
`SKIP_TAGS` from `/opt/tockmox/etc/ai-node.env`; until you do, the converge job,
the facts job and the readiness textfile are not installed.

Adoption is best effort. It does not promise byte-identical LaunchDaemon files.
Read the preview, and expect the first real converge to rewrite the files whose
rendering differs.

## What it does not do

- It does not manage an Apple Account, FileVault, MDM or the console settings in
  the checklist above.
- It does not run on Linux. Every role stops with a message that says so.
- It does not fetch `modelkit` artifacts, install derived Ollama models, rotate
  engine logs, or take per-instance llama-server arguments (the arguments in
  `ai-node.yaml` are global to the engine).
- It does not decide what to serve. That is `site/values/models.yaml` and the
  [model lifecycle](model-lifecycle.md).
- It does not push to your site repository. The deploy key is read-only by
  construction.

## What is not certified here

**Executed, 2026-10-21, on Linux:** the lint gates (`shellcheck`, `yamllint`,
`ansible-lint` at the production profile, `ansible-playbook --syntax-check`);
the Python unit tests for the filters, the model helper, the pf evidence reader
and the templates; the converger wrapper against a real git repository with
signed commits, a rotation and a rewritten history, with a fake `ansible`; the
bootstrap script end to end against fakes of the macOS tools; and the whole
playbook twice against stand-ins for `launchctl`, `pfctl`, `dscl`, `pmset`,
`defaults` and the others, with the second run reporting no change. Run them with
`tools/check-ai-node.sh`, and the simulation with `tools/check-ai-node.sh --e2e`
as root on Linux.

**Not executed:** anything on a Mac. The stand-ins test the playbook's own logic
(order, idempotence, refusals), and they encode what the macOS commands were
believed to print. A belief that is wrong makes a role fail or, worse, pass. Run
each command below on the node after the first converge; each line is something
the toolkit assumes.

| Assumption | Command that settles it |
|---|---|
| `sysadminctl -addUser ... -password -` takes a password on a pipe, and the accounts come out as intended | `dscl . -read /Users/inference IsHidden UserShell` and `dscl . -read /Groups/admin GroupMembership` |
| Handing `/opt/homebrew` to `tockmox` leaves `brew` working for it | `sudo -u tockmox /opt/homebrew/bin/brew list --versions ansible` |
| pf evaluates the sub-anchor `com.apple/250.tockmox` through Apple's stock wildcard anchor | `sudo pfctl -sr \| grep 'com.apple'` and `sudo pfctl -a com.apple/250.tockmox -sr` |
| An engine port is closed to a host outside `engineAllowFrom` | `nc -vz mac.example.com 8080` from such a host |
| `flags any` keeps an SSH session that predates pf alive | run the first converge over SSH and watch it survive |
| The `pfctl -ss` state lines are read as the evidence parser expects | `sudo pfctl -ss \| grep ESTABLISHED` during an SSH session |
| The timed rollback runs detached as a one-shot job bootstrapped from `/var/db/tockmox-ai-node/pf-rollback.plist` (`launchctl submit`, used before, returned 0 and started nothing visible on macOS 27.0.1) | `sudo launchctl print system/com.tockmox.ai-node.pf-rollback` just after an administrator-rule change |
| The rollback puts the last confirmed rules back and the managed ports stay closed | after an unconfirmed change and five minutes, `sudo pfctl -a com.apple/250.tockmox -sr` shows the old rules, including a `block` line |
| `sysctl -n kern.boottime` prints `{ sec = N, usec = M } ...` and the braces part does not change during a boot, also after a clock step | `sysctl -n kern.boottime` before and after `sudo sntp -sS time.apple.com`, and `cat /var/db/tockmox-ai-node/pf-boot-ok` |
| `pfctl -a com.apple/250.tockmox -sr` prints the block rule as a line that starts with `block` | `sudo pfctl -a com.apple/250.tockmox -sr \| grep '^block'` |
| An engine does not listen while the marker is absent, and starts when pf-load writes it | `sudo rm /var/db/tockmox-ai-node/pf-boot-ok`, `sudo launchctl kickstart -k system/com.tockmox.ai-node.ollama`, `sudo lsof -nP -iTCP:11434 -sTCP:LISTEN` (nothing), then `sudo /usr/local/libexec/tockmox-ai-node/pf-load.sh` and the same `lsof` (a listener) |
| After a restart no engine listens before the allowlist is loaded | restart, then `sudo launchctl print system/com.tockmox.ai-node.ollama` and `/opt/tockmox/log/ollama.log` for the "waiting for the firewall" line |
| `launchctl bootout` of an engine from the stop script ends its listener | `sudo /usr/local/libexec/tockmox-ai-node/stop-listeners.sh` and `sudo lsof -nP -iTCP -sTCP:LISTEN` |
| `hf download --revision` stores the commit as the snapshot name (seen on macOS 27.0.1 with hf 2.2.0; its blobs for Xet-backed files are named by the Xet hash, which the helper now checks against the Hub) | `ls /opt/tockmox/models/hf/hub/models--*/snapshots/` |
| An Ollama manifest file hashes to the registry digest | `shasum -a 256` of the file under `/opt/tockmox/models/ollama/manifests/` equals the pinned digest |
| `sshd -t` accepts the drop-in | `sudo sshd -t` and `sudo sshd -T \| grep -i allowusers` |
| The facts writer can read what it needs as the service account | `sudo -u inference /opt/tockmox/bin/tockmox-ai-node-facts` then `cat /opt/tockmox/textfile/facts.prom` |
| macmon serves its metrics and its bind address | `lsof -nP -iTCP:9101 -sTCP:LISTEN` |
| `iogpu.wired_limit_mb` exists and takes the value on this macOS | `sysctl iogpu.wired_limit_mb` |
| A converge can reload its own LaunchDaemon without dying | change the interval in `fleet.yaml`, then `sudo launchctl print system/com.tockmox.ai-node.converge` after the run |
| The Apple Account check finds a signed-in account | `sudo defaults read /Users/admin/Library/Preferences/MobileMeAccounts Accounts` |
| The scripts run under macOS's bash 3.2 | `/bin/bash --version` and `/bin/bash -n /opt/tockmox/bin/tockmox-ai-node-converge` |

Two things are decisions, not measurements: that a deploy key which can write is
refused (the check relies on the forge's error text for a read-only key), and the
default grace period for an unreferenced model.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

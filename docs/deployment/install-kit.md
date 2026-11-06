---
okf_version: "0.2"
type: HowTo
title: "Install with the kit"
description: "Run the installer and every tool it needs from one container you build yourself, so your workstation needs a container runtime and nothing else. Optional: the same scripts run natively from a clone."
tags: [deployment, install, installer, container, workstation, prerequisites, docker, podman]
status: stable
generated:
  by: hand
  at: 2026-11-05
tockmox:
  classification: public
  audience: [operator]
---

# Install with the kit

**The kit is the installer in a container.** It carries `install/tockmox-install.sh`
and every tool the install pages ask your workstation for (`kubectl`, `helm`,
`kubeseal` at the controller's version, `git`, `openssl`, `age`, `python3`,
bash 5), at the versions the release was tested with, each checked against a
pinned SHA-256 when the image is built. Your workstation needs one thing: a
container runtime that is running.

It is optional. Every command on [install](install.md) runs natively from a
clone, exactly as before, and the kit runs the **same scripts**: it adds no
second installer. Use it when you would rather not install and version-match
six tools, or when your workstation is a Mac whose bash and BSD tools the
native route has to work around.

**Tockmox publishes no image.** You build the kit on your own machine from the
release's source, like everything else Tockmox distributes
([why](../why-tockmox.md)).

## Before you begin

| What you need | Why | How to check |
|---|---|---|
| A container runtime, running: Docker (Docker Desktop, OrbStack, Colima, Rancher Desktop in dockerd mode), Podman, or nerdctl | Builds and runs the kit. Any one; the launcher uses the first whose daemon answers | `docker info`, `podman info` or `nerdctl info` succeeds |
| About 400 MB of image space, and internet access for the build | The build downloads Alpine packages and three release binaries | |
| A kubeconfig that reaches the cluster at an address other than 127.0.0.1 | The kit mounts one kubeconfig read-only. Inside the kit, 127.0.0.1 is the kit | `kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'` prints the cluster's own address |

**Docker Desktop's licence.** Docker Desktop is free for personal use, education,
non-commercial open source and organisations under 250 people and under $10M
revenue; larger organisations and government need a paid subscription
([Docker's terms](https://docs.docker.com/subscription/desktop-license/)). The
kit does not need Docker Desktop specifically. Podman, Colima and Rancher
Desktop work the same way.

**Where each command runs.** Every block below runs on your workstation, in the
directory that will hold your `tockmox.yaml` and your site. That directory is
mounted into the kit as `/work` and is the only part of your machine it can see.

## 1. Get the launcher ... Required

`tockmox-kit` is a short script that builds and runs the kit with the right
mounts. Take it from a clone, or download it on its own:

**WORKSTATION**

```bash
curl -fsSLO https://raw.githubusercontent.com/tockmox/tockmox/v0.9.0/install/kit/tockmox-kit
chmod +x tockmox-kit
```

**Passes when:** `./tockmox-kit kit-check` starts and complains only that there
is no `tockmox-kit` image yet. In a clone, the launcher is
`install/kit/tockmox-kit` and every `./tockmox-kit` below is that path.

## 2. Build the kit ... Required

Build it from the release you intend to install. With `--ref`, the runtime
fetches that tag's source from GitHub itself, so no clone and no local `git`
are needed. In a clone, leave `--ref` off to build from the clone.

**WORKSTATION**

```bash
./tockmox-kit build --ref v0.9.0
```

**Behind a proxy that intercepts TLS**, add `--ca-file proxy-ca.pem` (your
proxy's CA, in PEM). It is passed to the build as a secret, used for the
downloads, and kept out of every layer of the image.

**Passes when:** the build ends with the image named `tockmox-kit`, and the log
shows `helm.tgz: OK`, `kubectl: OK` and `kubeseal.tgz: OK`. A checksum mismatch
stops the build with nothing installed; it means the download is not the file
this release was tested with, and the right response is to stop, not to edit
the checksum.

## 3. Check it ... Required

**WORKSTATION**

```bash
./tockmox-kit kit-check
```

**Passes when:** every line starts `ok` or `info`, the `kubeconfig` line names
the context you expect, and the exit status is 0. A `FAIL` line names the tool
and the version it found.

## 4. Run the install through it

From here, follow [install](install.md) and [the cluster preparation
pages](prerequisites.md) as written, with one substitution:
**wherever a page runs `install/tockmox-install.sh`, run `./tockmox-kit` with the
same arguments.** The subcommands are the installer's own, unchanged:

| The page says | Through the kit |
|---|---|
| `./install/tockmox-install.sh --config tockmox.yaml` | `./tockmox-kit --config tockmox.yaml` |
| `./install/tockmox-install.sh bootstrap-secrets --mode new ...` | `./tockmox-kit bootstrap-secrets --mode new ...` |
| `./install/tockmox-install.sh bootstrap-forge ...` | `./tockmox-kit bootstrap-forge ...` |

The installer's printed next steps already name `./tockmox-kit` when it runs
inside the kit. Paths it prints under `/work` are paths in your directory.

**A page's other commands** (`helm repo add`, `kubectl apply`, the checks) run
inside the kit with `shell`. Each `./tockmox-kit` call is a fresh container, so
run a page's consecutive blocks in one shell, not one call per block:

**WORKSTATION**

```bash
./tockmox-kit shell
```

**Passes when:** the prompt that opens runs `kubectl get nodes` against your
cluster. `exit` leaves it, and nothing it did outside your directory remains.

## Trusting a private CA

The kit trusts the public CAs in its image. To trust another one as well (the
private CA your forge or registry is served with, or a proxy's), pass it on
every run:

**WORKSTATION**

```bash
./tockmox-kit --ca-file site-ca.pem kit-check
```

**Passes when:** `kit-check` prints `info  extra CA: /kit/ca.pem added to the
trust bundle`. The CA is added to the image's bundle, never replacing it, for
`curl`, `git`, Python and the Go tools alike.

## What the kit cannot see, and what it keeps

| Situation | What happens | What to do |
|---|---|---|
| A file argument given as an absolute path | The launcher warns: the kit sees only your directory | Copy the file into the directory and give a relative path |
| `KUBECONFIG` lists several files | Refused before anything runs | `kubectl config view --flatten > kit-kubeconfig`, then `--kubeconfig kit-kubeconfig` |
| The kubeconfig's server is 127.0.0.1 or localhost (a tunnel, a port-forward, a cluster on your laptop) | The launcher warns; inside the kit that address is the kit | Use the cluster's own address. On Docker Desktop, `host.docker.internal` reaches your machine, if the cluster's certificate names it |
| A context that authenticates with an exec plugin (an OIDC login helper, a cloud CLI) | The plugin is not in the kit, so the call fails | Use a context with a token or client certificate, or run that step natively |
| A kubeconfig that names certificate files by path | The files are not mounted | `kubectl config view --flatten --minify > kit-kubeconfig` embeds them |

**What it leaves on your machine:** only what the installer writes into your
directory, owned by you. Credentials are generated in the kit's memory (a tmpfs
at `/tmp`) and only their sealed form reaches your directory; the container is
removed when each call ends. The sealing-key backup lands where
`--backup-out` points, encrypted, as it does natively.

## What has been tested, and what has not

The kit was built and run on Linux x86_64 against a k3s v1.36.4 cluster: the
ArgoCD install from [fresh install](fresh-install.md) run verbatim inside
`shell`, site generation, and `bootstrap-secrets --mode new` end to end, with
every file the working directory held during the run checked for the minted
values, including a run killed while exporting the key. CI builds the image
on amd64 and arm64 and runs `kit-check` and the installer's own tests inside
it. **Not yet run:** Docker Desktop on macOS, Podman, and Windows. The kit is
not a [gated shape](deployment-shapes.md); the native route is what the release
gate exercises.

<!-- tockmox:footer:begin -->

---

<sub>Tockmox v0.8.0 &middot; &copy; 2026 Tockmox LLC &middot; code Apache-2.0, docs CC BY 4.0 &middot; Tockmox is a trademark</sub>
<!-- tockmox:footer:end -->

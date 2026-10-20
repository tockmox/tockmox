<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Security policy

Tockmox is maintained by one person. This document states what that person can
actually do, on what timeline, and what a reporter should do when a timeline is
missed. An acknowledgement window nobody can hold is worse than a long one that
is kept.

## Reporting a vulnerability

**Please do not open a public issue.** Two intake paths, both monitored:

1. **[GitHub private vulnerability reporting](https://github.com/tockmox/tockmox/security/advisories/new)**
   ... preferred. It is confidential, it keeps the report, the discussion, the
   fix and the advisory in one place, and it does not depend on email being
   read.
2. **security@tockmox.com** ... for reporters who cannot or will not use
   GitHub. No PGP key is published today, so treat this channel as
   unencrypted-in-transit and send the minimum needed to start the
   conversation; the rest can move to the private advisory.

Include:

- what the issue is, and what an attacker could achieve with it
- how to reproduce it, ideally as a manifest, a values file, or a command
- the Tockmox revision and the Kubernetes version and distribution
- whether you believe it is being exploited, and what you saw that suggests it
- whether you want to be credited, and under what name
- your own disclosure deadline, if you have one

**If you believe the issue is being actively exploited, put ACTIVELY EXPLOITED
in the first line.** That is not decoration; it routes the report to the fast
path described below.

## Response targets

These are targets for one person, not an SLA, and they are set where they can
be met on an ordinary week rather than a good one.

| Stage | Target |
|---|---|
| Acknowledgement that a human has read it | 3 business days |
| Acknowledgement, actively-exploited reports | 24 hours, best effort |
| Assessment: severity, scope, and whether it is a vulnerability at all | 10 business days from acknowledgement |
| Fix | Severity-driven. No date is promised, and progress is reported rather than assumed |
| Advisory and credit | Published with the release that carries the fix |

**When a target slips.** The failure mode of a solo project is silence, not a
decision, and silence should not cost the reporter anything. So:

- If you have heard nothing after **10 calendar days**, assume the message went
  astray and re-send through the other intake path.
- The embargo clock below runs from the date you sent the report, not from the
  date it was read. A slow response shortens the embargo; it does not extend
  it.
- You are never obliged to wait past the embargo window for a project that has
  gone quiet.

## Coordinated disclosure

The expectation is coordinated disclosure, stated as terms rather than as a
request for trust:

- **Default embargo: 90 days** from the date you send the report. If a fix
  ships sooner, the advisory publishes with it and the embargo ends there.
- **You may publish after 90 days**, whether or not a fix exists, and doing so
  is not a breach of anything. If more time would genuinely help, it will be
  asked for with a reason and a date, and you are free to decline.
- **Credit by default**, under the name you choose, unless you ask otherwise.
- **A conclusion of "not a vulnerability" is still a conclusion** and comes
  with the reasoning, so you can disagree with it on the substance.
- Please do not test against infrastructure you do not own. Every property
  here is reproducible on a cluster of your own.

## Reports of actively exploited vulnerabilities

A report marked ACTIVELY EXPLOITED is handled on a faster path than the targets
above, in three steps: an early warning as soon as the report is credible, a
fuller notification once the scope is understood, and a final report when a
corrective measure exists. Each step goes to you and, where one is involved, to
the coordinating authority.

That shape is not a legal obligation this project carries; it is the shape that
works, and it is what a coordinating body will expect if one ever becomes
involved. The 24-hour acknowledgement target in the table above is the front of
it.

If you are a CSIRT, a national authority, or ENISA, security@tockmox.com
reaches the maintainer directly and is the address to use.

## Release signing key

Every release tag is SSH-signed. The allowed-signers file ships in-repo at
[`.gitsigners`](.gitsigners); the fingerprint is published here as well, so
that tampering with the key requires changing it in two files rather than one:

```
SHA256:EWYdV82fKSzUvXc5RPMuUH35J/CiQmBm7egYCDEmGDY   ED25519   jeff@maaks.com
```

Check a tag against it:

```bash
git config gpg.ssh.allowedSignersFile .gitsigners
git verify-tag v0.8.0
ssh-keygen -lf <(awk '{print $2, $3}' .gitsigners)
```

Two files in the same repository is a weak form of two places ... anyone who
can rewrite one can rewrite the other. It raises the cost of a silent swap, it
does not prevent a deliberate one. Verification that does not depend on this
repository at all is the honest bar, and it is not met yet: see
[verify.md](docs/deployment/verify.md).

If a published fingerprint ever changes without a signed announcement carrying
the old key, treat it as a compromise and report it through the channel above.

## Supported versions

Pre-1.0. The current release line (`release-X.Y`) receives patch releases:
fixes cherry-picked from `main` (backports) plus dependency updates. Only the
latest patch of the current line is supported; upgrading to it is the
remediation path. A line ends when the next minor's final tag ships: once
`vX.(Y+1).0` exists, `X.Y` receives no further patches. A security fix may ship
out of band, ahead of the normal patch cadence.

## Scope

**In scope:**

- Privilege escalation through anything Tockmox ships
- The admission guardrails failing open, or being bypassable
- Secrets exposure via the values interface or the generated manifests
- The diagnostic identity gaining any write capability, or reaching the
  internet
- Anything that causes a user's configuration to be overwritten by an upgrade
- A default in a shipped chart that is insecure without the operator being told

**Out of scope:**

- Vulnerabilities in upstream components that Tockmox does not misconfigure.
  Report those upstream; tell this project too, and the fix is a pin or a
  workaround
- Misconfiguration of your own cluster
- Anything requiring cluster-admin to exploit, since that is already game over
- Findings from a scanner with no demonstrated path to impact. A CVE in a
  transitive dependency of an image is a maintenance item, not a report; open a
  normal issue
- Denial of service against your own single-node deployment by exhausting its
  resources

## Security properties Tockmox tries to hold

Stated so you can test them, and so a failure of one is clearly a bug rather
than a design choice:

**The diagnostic identity cannot write.** Its ClusterRole grants `get`, `list`
and `watch` and nothing else. A path to a write is a vulnerability.

**The diagnostic identity cannot reach the internet.** NetworkPolicies permit
DNS, the API server and in-cluster telemetry. An egress path to anything else
is a vulnerability.

**cluster-admin grants are deliberate.** An admission policy denies
ClusterRoleBindings to `cluster-admin` unless explicitly allowlisted. A bypass
is a vulnerability. Note that this policy is *supposed* to block things ... see
[troubleshooting](docs/operations/troubleshooting.md) before reporting it.

**Secrets never leave your cluster.** Tockmox has no telemetry and no
phone-home. It ships secret *templates*; you seal your own against your own
key. Tockmox transmitting anything anywhere is a vulnerability and will be
treated as one. The claim is about what Tockmox sends, not about where every
byte sits: `tools/mint-secrets.sh` creates credentials on the machine you run
it on and seals them before they reach git, and `install/tockmox-install.sh
bootstrap-secrets` exports the sealed-secrets controller's private key,
encrypted, to a file outside the cluster that you keep, because a rebuilt
cluster cannot read your committed SealedSecrets without it. Credentials you
give to a model provider or another integration go where you send them.

**Upgrades cannot overwrite your configuration.** Your values live in a
separate repository. An upgrade path that can write to it is a serious bug.
This is a property of files; before 1.0 it does not promise that the names and
endpoints an application of yours depends on stay put
([values contract](docs/administration/values-contract.md#before-10-there-is-no-downstream-abi)).

## Known issues

Current known security-relevant issues are listed in
[CHANGELOG.md](CHANGELOG.md) under "Known issues". They are public because they
are already visible in the code, and hiding them would help nobody.

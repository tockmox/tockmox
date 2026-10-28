# Inventory of documented paths

## About the evidence logs, and about `TM-`/`HL-` identifiers

**Read this before the table, because it bounds what the "Evidence:" column is
worth to you.**

Rows below cite run logs by filename — `EVIDENCE-2026-09-02-A5-installer-end-to-end.log`
and similar. **Those logs are maintainer-held and are not in this repository.**
Until 2026-09-03 the citations carried a `Tockmox/` path prefix, which pointed
into a private working repository and was therefore a reference an outside
reader could neither follow nor audit. The prefix is gone; the limitation it
accidentally disclosed is real and is stated here instead.

So: **a cited log is a claim, not evidence you can check.** What you *can* check
is in this repository — the path scripts under `paths/`, their assertions, and
`selftest.sh`. Where a row's finding matters to you and the script does not
settle it, the honest answer is that you are taking a maintainer's word for it.
Publishing sanitised logs is tracked; it is not done.

`TM-####` and `HL-####` are the maintainer's internal tracker. They appear
throughout this repository as provenance for a decision or a defect. **They do
not resolve publicly and nothing here depends on resolving one** — every such
reference is written so the surrounding sentence stands on its own. Read them as
you would a changelog entry's ticket number in any project whose tracker you
cannot see.

---

**Status: 2026-09-14.** Two path scripts exist that the 2026-09-02 block below
predates, and the harness has since run as one suite rather than one path at a
time. `P08-existing-cluster-checks.sh` is STAGED. **`P09-install-md-end-to-end.sh`
is EXECUTED**: every WORKSTATION block of `install.md` fed to an interactive zsh
on a pseudo-terminal as a bracketed paste, one session with its exports carried,
against a throwaway cluster ... 22 steps, 47 assertions, 45 pass, 0 fail, 2
xfail, and three documentation defects found that no review had. The **full
run under route waves** then executed all four route groups against clusters
`run.sh` rebuilt between them: **8 executed, 0 failed**, P01 declared absent at
`main` by design and P03 blocked on its node transport. Counts below the line
are as they stood on 2026-09-02 and are kept rather than rewritten, which is
this file's own convention.

**Status: 2026-09-02. SEVEN documented paths executed — SIX of them against a
live cluster, and one (B7) that needs no cluster at all. The first reproduced a
real defect by running it; the third proved the only documented ArgoCD route
(TM-0299) actually works; the fifth (P05) confirmed the sealed-secrets install
route works and named the release-name assumption its own success condition
depends on; the sixth (P06) settled the other named risky assumption — the
ArgoCD metrics service naming — and found a real documentation defect one
level up from the naming question the run sheet asked about; the seventh (P07)
closed A2's remaining half — a real secret sealed, applied and decrypted back
to the exact value that went in — and found a SECOND, more consequential
documentation defect in the same family P05 flagged: the page's own worked
example, and the script it tells readers to run instead, both invoke `kubeseal`
with no `--controller-name`/`--controller-namespace`, and both therefore fail
outright against a controller installed via this repo's own documented route.**

**That defect is broader than the page P07 tested, and it is now FIXED
(TM-0346, 2026-09-02, same day).** Those two flags appeared **nowhere** in
`docs/`, `tools/` or `install/`, across **six** call sites: the worked example
and the `seal()` helper in `administration/secrets.md`, the real
`tools/mint-secrets.sh` (twice ... its `seal()` and its own `--help` heredoc,
which is the sixth and was found while fixing), the backup credential in
`operations/backup-restore.md`, and `--fetch-cert` on the air-gap path in
`deployment/airgap.md`. Two of those reach beyond this inventory — one is a
recovery procedure, whose failure mode is discovering the seal never worked at
the moment you need the restore, and the other is exercised by the release gate.
**The failure is silent on the artefact: `kubeseal` writes a 0-byte file**,
created by the `>` redirect before kubeseal ever runs, so a reader gets a file
that looks minted and is empty.

**CORRECTED 2026-09-02: it is not silent on the exit code.** This file
previously said "and exits 0, so every exit-code check passes". That was never
measured — P07 states outright that the exit code is not its assertion — and it
is wrong: on kubeseal 0.30.0 the documented pipeline exits **1**. The claim is
kept visible here rather than quietly deleted, because it is the second time an
unmeasured number in this file turned out to be wrong, and both times it read as
settled.

The two numbers are kept separate on purpose. "Executed" and "executed against a
live cluster" are different claims, and collapsing them would let cheap
registry-only checks inflate a figure that readers will take as cluster
coverage.

The harness provisions a throwaway single-node k3s cluster, runs the documented
commands verbatim out of the page at a git ref, and asserts on artefacts. First
run reproduced TM-0288 from the published text, and the recovery path proved the
assertion has a green state. That is the smallest-first-slice bar met.

Everything else in this file is still STAGED, OPEN or EXCEPTION, and the gap
between "seven paths execute" and "the documentation is covered" is the whole
reason this inventory exists rather than a build badge.

This file, not a green build badge, is the answer to "what is covered?"
[The testing standard](../../docs/testing-standard.md) rule 2: the characteristic
deliverable is an inventory, because the unit of coverage is *a thing we told
someone is true*, and the interesting half of any inventory is its exceptions.

## How to read the status column

| | Meaning |
|---|---|
| **EXECUTED** | A gate ran this procedure against a live cluster and asserted on artefacts. The evidence column names the run. |
| **STAGED** | A path script exists, extracts the command verbatim, and has never run against a cluster. **Not coverage.** It is an intention with a file behind it. |
| **EXCEPTION** | Deliberately not tested. The reason column says why, and what would change it. "Hard" is not a reason. |
| **OPEN** | No gate, no exception. Visible here so that it is a known gap rather than an invisible one. This column existing is the point of the whole document. |

The distinction between STAGED and EXECUTED is the one that will be tempting to
blur, and blurring it is how this project got into the position TM-0289
describes. A path script that has never run is worth slightly more than nothing:
it proves someone decided what to assert. It proves nothing about the software.

## The denominator

Measured over `docs/` on `main`, 2026-09-10 (first measured 2026-09-02):

- 465 fenced bash blocks across 43 pages (re-measured 2026-09-14: 331 became 335, the four blocks of troubleshooting.md's new cached-upstream-failure entry, all procedure steps; then 335 became 336 later the same day, the single block of troubleshooting.md's new CRD-establishment-race entry ... a diagnostic `grep -c` over the application-controller log, a procedure step and OPEN like the rest of that page; then 336 became 337 on 2026-09-16, the single block of verify.md's new § 4 gate-report check, a reader-facing verification step and OPEN; then 337 became 339 on 2026-09-17, one WORKSTATION block in fresh-install.md § 6 confirming ArgoCD's metrics Services after TM-0628 moved the values into the install command, and one NODE block in uninstall.md's new step 9 confirming a transactional-OS teardown after the reboot TM-0624 documents; then 339 became 341 later the same day, the two complete openSUSE MicroOS install blocks fresh-install.md section 4a gained when TM-0719 found that on the OS the page recommends the k3s command could not be run as printed ... the reader had to hand-splice two environment variables into the middle of a curl pipeline; then 341 became 345 on 2026-09-24, the four blocks of troubleshooting.md's new pinned-failed-revision entry (TM-0627): one diagnostic, two remedies, one verify, all procedure steps and OPEN like the rest of that page; then 345 became 346 on 2026-09-29, the one WORKSTATION block of install.md's new bootstrap-secrets route in Phase 2.5 (TM-0277), a procedure step, NOT executed by P09 (P09 selects blocks by signature and the new block matches none) and OPEN; then 346 became 348 on 2026-09-29, the two blocks of troubleshooting.md's new Pod Security refusal entry (TM-0135): one diagnostic, one verify, both procedure steps, NOT executed and OPEN) Then 348 became 374 on 2026-09-29, and the page count rose to 35: the 26 blocks of three new pages (`operations/sealed-secrets-key-escrow.md`, `deployment/time-sync.md`, `operations/kube-bench.md`), all reader-facing procedure steps, all OPEN, none executed against a cluster. Then 374 became 376 on 2026-09-30: the two blocks of upgrade.md's new LiteLLM migrations-Job section (delete the Job, then sync), found by the 0.7.0 lab pass; procedure steps, OPEN. Then 376 became 378 on 2026-09-30 (second lab pass): that section is now three blocks (wait for the error and delete the Job, the fallback sync, the verification), and the docs sync section gained one (`create job --from=cronjob`); procedure steps, OPEN, not executed by P09. Then 378 became 382 on 2026-10-03 (0.7.1 wave): uninstall.md gained four blocks, step 1's Longhorn pre-delete pre-check and hook-Job read (TM-0563) and step 3b's list-and-delete of the volumes a Retain StorageClass leaves Released (TM-0789); procedure steps, OPEN, not executed. Then 382 became 387 on 2026-10-03 (0.7.1 wave 2), and the page count rose to 36: the three blocks of the new `administration/removing-an-application.md` (TM-0800), one capture block in install.md 3c (TM-0629) and one in uninstall.md 7e listing Tockmox's CRDs by group (TM-0564); procedure steps, OPEN, not executed. Then 387 became 389 on 2026-10-06 (wave 080): install.md's new step 1f (TM-0798), one block that appends each node's gateway list to the policy values and its success condition; procedure steps, executed by P09 as S09b. Then 389 became 392 on 2026-10-06 (TM-0596, TM-0912): upgrade.md's new 0.8.0 migrations-Job section (the prune-by-hand delete and its success condition) and install.md's new grant step after the model-gateway key; procedure steps, OPEN, not executed by P09 (its model-gateway gate finds LiteLLM off). The install.md block was run verbatim on a lab greenfield the same day. Then 392 became 393 on 2026-10-07 (TM-0844): uninstall.md's new "Name the cluster" block, which exports KUBE_CONTEXT and prints the API server it resolves to; a procedure step, OPEN, not executed. The same change added a guard line and `--context` to 41 existing uninstall.md blocks and 8 upgrade.md blocks without adding blocks (upgrade.md's export joined its existing "you supply" block). On 2026-10-08 the count stayed 393 across two changes: TM-0897 removed external-integrations.md's DNS check block (the page now points at install.md's) and replaced install.md's DNS success condition with a random-label lookup from the workstation and a pod, a procedure step executed by P09 as S21b when `TOCKMOX_P09_LAN_RESOLVER` names a resolver holding the wildcard and skipped with a note otherwise; TM-0909 added one `jq` block to values-contract.md, a reader-facing read, OPEN. Then 394 became 410 on 2026-10-08, and the page count rose to 37: the 16 blocks of the new `deployment/upgrade-foundations.md` (TM-0907), reader-facing procedure steps for upgrading ArgoCD and k3s, all OPEN, none executed against a cluster. Then 410 became 414 on 2026-10-09 (TM-0622): fresh-install.md gained four NODE blocks, the MicroOS variants of the 4c server join and the 4d worker join, the 4d worker's `restorecon` and `systemctl enable --now k3s-agent`, and 4e's worker check; procedure steps, OPEN, the 4c and 4d MicroOS joins not executed as printed (L3 ran the unskipped joins plus the fix block). Then 414 became 416 on 2026-10-09 (TM-0982): ai-plane.md's new "When the gateway rejects the console's key" gained two WORKSTATION blocks, the Job re-run and the check's last verdict; procedure steps, OPEN, not executed Then 416 became 415 on 2026-10-12, for the first public release: verify.md's "verifying v0.5.0" block (a clone and `git verify-tag` of a tag that exists only in the private history) was removed, and install.md's precondition `ls-remote` now names `refs/tags/v0.8.0` (still one block, executed by P09 as S04). Then 415 became 417 on 2026-10-20: administration/identity.md's new section on a changed blueprint reaching Authentik gained two blocks, the diagnostic that reads the worker's `Liveness probe failed` event and the `rollout restart` for a blueprint the probe does not cover; reader-facing procedure steps, OPEN, not executed by P09. Then 417 became 421 on 2026-10-21, and the page count rose to 38: the four blocks of the new `administration/ai-nodes.md` (the bootstrap one-liner, the adoption variant, a `--rebaseline`, and a read of the node's textfiles), all reader-facing, all OPEN, none executed by P09 because they need a Mac. Then 421 became 422 on 2026-10-23, and the page count rose to 39: tockmox-ui.md's first block, which seals the Authentik half of the UI's client secret from the value an install minted before 0.9.0 already has (TM-0956); a reader-facing procedure step, OPEN, not executed by P09. Then 422 became 424 on 2026-10-26, and the page count rose to 40: platform-management.md's first two blocks, the `tools/gen-platform-specialists.py` commands in its new Cases section (one rewrites the catalog's specialists field, one runs `--check` for drift; two blocks so neither carries a comment); reader-facing steps run from a repository checkout, OPEN, not executed by P09 (they touch no cluster). Then 424 became 431 on 2026-10-27 (TM-0788, Authentik on CloudNativePG): upgrade.md's new "Move Authentik's database to CloudNativePG" gained five WORKSTATION blocks (the stopped-Authentik check, the dump and user count from the bundled server, the new cluster and retained-volume check, the restore and recount, the old volume's deletion), secrets.md gained one (sealing `tockmox-authentik-db` from the live Secret for an install minted before 0.9.0) and backup-restore.md one (the identity drill's register read); reader-facing procedure steps, OPEN, not executed by P09, and the move procedure is marked not yet proven on its page. Then 431 became 439 on 2026-10-27 (TM-0120): airgap.md's new step 8, the update path for a disconnected install, gained eight blocks (the revision exports and tag check, the `images.txt` and `Chart.lock` diffs, the dry run from the target tree, the archive re-vendor, the bundle create, the inside fetch, verify and push, the inside proof, and the pull-failure grep); procedure steps, OPEN, not executed, and the page says so. Then 439 became 462 on 2026-10-27 and the page count rose to 42 (TM-0784, TM-0842): the new administration/bring-your-own-ca.md gained ten WORKSTATION blocks (the namespace lookup, the CA checks, the seal, the adoption of the chart's key, the fingerprint read and the issued-certificate proof) and the new operations/second-site-dr.md thirteen (the five readiness checks, the context guard, the key restore, the recovery-values check, the root apply, the unseal check, the database proof and the volume read); procedure steps, OPEN, not executed, and both pages say so. Then 462 became 464 on 2026-10-28 (TM-1196, TM-1054): upgrade.md's new 0.9.0 section on the LiteLLM migrations Job becoming an Argo CD hook and the pre-upgrade backup gained two WORKSTATION blocks, the delete of the old hash-named Job and the read of the pre-upgrade Backups; reader-facing procedure steps, OPEN, not executed by P09. Then 464 became 465 on 2026-10-28, and the page count rose to 43: administration/namespace-guard.md's one WORKSTATION block, a read that the policy and its binding exist after the policy layer syncs; a reader-facing procedure step, OPEN, not executed by P09.
- 8 console transcripts, which are recorded output rather than instructions

**Re-measured 2026-09-10: 295 became 298.** Three blocks, all real procedure
steps rather than assignments, so all three belong in the denominator:
TM-0490's schema-substance assertion on `backup-restore.md` §5 (the fallback
success condition for the shipped database, where the reader has no named row
of their own to read back), and TM-0489's two on `install.md` ... the
authenticated publish that proves the last hop, and the `ntfy_subscribers_total`
read that explains it when nothing arrives.

**Re-measured 2026-09-10: 294 became 295.** One block, TM-0469's
`export KUBE_CONTEXT` preamble on `fresh-install.md`, which is the same shape
as the four `export SITE_REPO=...` preambles below: an assignment a reader
performs, not a procedure step, and OPEN like the rest of them.

**The harness now exports `KUBE_CONTEXT`, and rows A1b, A2 and B6 depend on
it (2026-09-10).** TM-0469 put a `: "${KUBE_CONTEXT:?}"` guard on five bash
blocks across sections 6 and 7 ... the sections P04 and P05 extract and run
verbatim through `bash -c`. With the variable unset every one of those blocks
fails at its first line, so the page had become stricter than the harness,
which had only ever identified its cluster by `KUBECONFIG` plus
current-context. `run.sh` now derives the context from the guest kubeconfig it
just created and exports it, and refuses to run the paths at all if that comes
back empty ... because `--context=` with an empty value silently means
current-context, which is the precise failure the guard exists to prevent.
This was caught by the CI anchor canary, not by a path run: the three rows are
marked EXECUTED against runs that predate the guard, and none of them has been
re-run since.

**Re-measured 2026-09-04: 289 became 294**, five blocks on pages already in
the denominator, all OPEN. Four are the `export SITE_REPO=...` preambles that
replace the three spellings of the site-repository placeholder (`day-2.md`,
`upgrade.md`, `capabilities.md`, `customising.md`; see the documentation
standard, rule 5). The fifth is not new text: `install.md` §3b's
`helm template charts/tockmox-policy ... | sort | uniq -c` render check sat
inside a `>` blockquote admonition, and a fenced block behind a `>` prefix is
neither matched by this denominator's scan nor extractable by
`lib/extract-block.sh`. It was reported as a PS2-prompt transcript by a static
sweep (TM-0403), which is a misreading of the blockquote markers ... but the
invisibility was real, and the block is a plain fence now. It was the only
such block in `docs/`.

**Re-measured 2026-09-04: 288 became 289**, one block added on a page already
in the denominator ... `configuration.md` now gives the `kubectl port-forward`
that reaches the Traefik dashboard, which needs the new `traefik.api.insecure`
key to answer at all. OPEN.

**Re-measured 2026-09-04: 287 became 288**, one block added on a page already
in the denominator ... `uninstall.md` §7d now gives a
`kubectl get validatingadmissionpolicybinding` command, so a reader on a cluster
someone else configured can read the policies' `validationActions` off the
cluster rather than trusting the table. OPEN.

**Re-measured 2026-09-04: 286 became 287**, one block added on a page already
in the denominator ... the `values-contract.md` stability-tier `jq`, which
lands with the per-key tiers. OPEN.

**Re-measured 2026-09-03: 283 became 286**, three blocks added on pages
already in the denominator (the `install.md` Phase 1 precondition's
`git ls-remote`, the `airgap.md` §2 `--verify` success condition, and the
`values-contract.md` open-blocks `jq`), all OPEN.

**Re-measured 2026-09-02 PM, after `docs/agent-skills/` landed: it was 273
across 27.** The four new pages carry 10 blocks between them, and every one of
those is a diagnostic or derivation command quoted from a page already in this
denominator rather than a new documented install path. **They are counted
anyway, and they are OPEN.** Carving an exemption so the number did not move
would have been the cheaper edit and the wrong one: the denominator is "the
documentation surface a reader walks", the agent skills are walked by a reader,
and this file's whole argument is that a surface excluded from the count is a
surface nobody notices going untested. If a later pass decides an agent-facing
page is categorically not a path, that is a scope decision to argue in
`tools/doc-claims.txt` with its reason, not a quiet change to the scan.

These three numbers are asserted in `tools/doc-claims.txt`, so a commit that
changes the docs and leaves this paragraph behind goes red. They were not, until
2026-09-02, and the page count was already wrong by one when someone checked.
A file whose whole argument is that unasserted claims are how defects survive
should not carry unasserted claims.

A block is not a path ... a single procedure often spans several blocks, and
`install.md` alone carries 37 (re-counted 2026-09-04). The inventory below is at **procedure**
granularity, which is the unit the standard defines. The block count is here as
the surface being drawn from, so that a reader can see how much of the page
estate this inventory does and does not reach.

**This inventory enumerates all 43 pages (section E, 2026-10-27), and covers the paths
TM-0289 named plus the nine `documentation-steward` could-not-verify items in
rows A to D.** Enumerating a page is not covering it: section E says which pages
have a block executed against a live cluster, and every other row is OPEN or a
written EXCEPTION, because an untested path absent from the inventory is
invisible, and invisible is how both 2026-09-01 defects survived.

---

## A. The TM-0289 first-pass inventory

| # | Path | Documented at | Status | Evidence / reason |
|---|---|---|---|---|
| A1a | ArgoCD prerequisite, **raw manifest** | `deployment/prerequisites.md` §2 @ v0.6.0-rc1 | **EXECUTED 2026-09-02** | `paths/P01-argocd-raw-manifest.sh`, 3 assertions, 2 pass + 1 XFAIL. The documented command, run verbatim from the page, failed on the cluster with `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`. TM-0288 reproduced by execution rather than by reading. See *What the first run proved* below. **2026-09-04: P01 reports an EXCEPTION at `main`, and that is now the correct answer (TM-0422, fixed).** It hardcoded `deployment/prerequisites.md` § "2. ArgoCD, 2.6 or newer", restructured away in f2dd829 on 2026-09-01, and exited **2** with no override and no exception branch ... so `run.sh` reported `FAILED` for a harness reason from 09-01 to 09-04, and **A1c ran that whole time without the half-applied state it repairs.** It now takes `TOCKMOX_P01_PAGE` / `TOCKMOX_P01_SECTION` and exits **3** when the section is absent, which `run.sh` counts as SKIPPED. **The route is not documented at `main` by design** ... `argocd.md` says Helm is the only documented route and shows the client-side command only as failure output, never as a runnable block ... so a skip there is a fact about the docs, not a gap. Run it at **`24e3a9b`**, the last ref publishing the route, to exercise it and to give A1c its precondition: verified 2026-09-04, XFAIL plus 2 PASS, and A1c then PASS 2/2 behind it. P02 now says in `does_not_prove` what it loses when P01 skips. |
| A1b | ArgoCD prerequisite, **Helm** | `deployment/fresh-install.md` §6 | **EXECUTED 2026-09-02** | `paths/P04-argocd-via-helm.sh`, 3 assertions, all pass. Block 1 (`helm search repo argo/argo-cd --versions \| head -5`) was run and its own output read to resolve `<CHART_VERSION_FROM_ABOVE>` — this run substituted chart `10.6.4` / appVersion `v3.5.2`, recorded in the run log rather than hard-coded. All three of the page's own stated success conditions pass, including `kubectl get crd applicationsets.argoproj.io` and the image-tag read that proves the 2.6 floor. TM-0299's Helm route has now run at least once. |
| A1c | ArgoCD **server-side** recovery | `administration/argocd.md` §"If you install from the raw manifest anyway" | **EXECUTED 2026-09-02** | `paths/P02-argocd-server-side-recovery.sh`, 2 assertions, both pass. The CRD reports `Established=True` and carries no `last-applied-configuration` annotation, which tests the page's stated *mechanism* and not just its outcome. **The page's own "Unverified" admonition is now discharged** ... hand that wording change to `documentation-steward`. Also the control for A1a: it proves that assertion has a green state. |
| A2 | sealed-secrets: install, key creation, sealing one real secret and reading it back | `deployment/fresh-install.md` §7 (install) + `administration/secrets.md` "## Sealing one" (seal round trip) | **EXECUTED 2026-09-02 — COMPLETE.** | Both halves now run. **Install half:** `paths/P05-sealed-secrets-install.sh`, 3 assertions, all pass, against a live cluster. Block 1 (`helm show chart`) read live to resolve `<CHART_VERSION_FROM_ABOVE>`, substituted `2.19.3` into block 2's install (recorded, not hard-coded). Block 3's success condition (`readyReplicas` prints `1`) passes. Block 4's key backup produced a 7083-byte non-empty file and `grep -c 'tls.key'` read 1, matching the page's own stated count. **Citation correction (install half):** the run sheet and this row previously named `deployment/prerequisites.md` §3 as the location. That heading does not exist on `main` — `prerequisites.md` was rewritten into a signpost on 2026-09-01 and now carries **zero** fenced bash blocks; it names sealed-secrets as one of three prerequisites and links straight to `fresh-install.md` §7 without repeating a command. `existing-cluster.md` "Check 6" and `administration/secrets.md` both cross-reference the same `fresh-install.md#7-...` anchor rather than documenting an independent route, so **there is no TM-0299-shaped divergence here** ... one route exists and this path tested it. **The risky half the run sheet named, confirmed:** the page's success condition (`kubectl -n kube-system get deployment sealed-secrets`) resolves only because the install command run immediately above it, verbatim from the same page, happens to name the release `sealed-secrets`. The page never states that the name is load-bearing. Evidence: run log `EVIDENCE-2026-09-02-P05-sealed-secrets.log` (maintainer-held; see "About the evidence logs" at the top of this file). **Seal-round-trip half (this row's remaining piece, now closed):** `paths/P07-sealed-secrets-seal-roundtrip.sh`, 4 assertions — 3 pass, 1 xfail. **Citation verified before writing anything:** `administration/secrets.md` "## Sealing one" exists character for character at `HEAD`, carries exactly one `bash` block, and — divergence flagged per rule 4 — states **no** "Success condition:" paragraph anywhere on the page (`grep -c -i 'success condition'` = 0; **method note 2026-09-04, TM-0351:** that grep matched one of the two phrasings the standard accepts, and would have read a "Passes when" page as stating none. `secrets.md` carries no "Passes when" on `main` today and gained its two "Success condition" paragraphs from TM-0346 after this run, so the divergence as written was true on both readings at the time; it is not one of the rows the single-phrasing grep got wrong. Every path script now records the census through `record_success_conditions`, never a bare grep); the assertions below are built from the page's own diagram and prose ("Only the controller running in your cluster can decrypt it") rather than a labelled success condition, because none exists. **A second, more consequential documentation defect found, in the same family P05 already flagged:** the block's own `kubeseal --format yaml`, run byte-for-byte (only the `api-key='...'` value placeholder substituted, with an obviously-synthetic canary generated at runtime), fails outright against a controller installed via this same ref's own documented route — `error: cannot get sealed secret service: services "sealed-secrets-controller" not found` — because kubeseal's own built-in default controller name (`sealed-secrets-controller`) never matches the release name `fresh-install.md` §7 installs under (`sealed-secrets`), and neither this page nor `tools/mint-secrets.sh`'s `seal()` helper (read, not executed) ever passes `--controller-name`/`--controller-namespace`. Pinned as XFAIL — the file the redirect creates is 0 bytes. **With harness glue** (the two flags kubeseal's own error names, explicitly flagged as not page text) the same otherwise-identical command produces a real `SealedSecret` that does not carry the plaintext (`grep -c` on the canary value = 0), and after applying it (harness glue standing in for the page's own "commit → git → sync", since this harness has no site-repository GitOps loop — that is A5, out of scope) **the controller decrypts it back to the exact synthetic value that was sealed** — `kubectl -n tockmox-ai get secret my-secret -o jsonpath='{.data.api-key}' \| base64 -d` reads `roundtrip-canary-<32 hex>`, matching what was sealed byte for byte. **That decrypted-value-equality assertion is the round trip run sheet item 5 asked for.** Suggested wording, not applied (hand to `documentation-steward`): add `--controller-name sealed-secrets --controller-namespace kube-system` to the `kubeseal` invocation in "## Sealing one", to the `seal()` helper under "## Secrets the platform expects you to create" on the same page, and to `tools/mint-secrets.sh`'s `seal()` function — lower blast radius than renaming the Helm release, since that would disturb P05's already-recorded finding. Evidence: run log `EVIDENCE-2026-09-02-A2-seal-roundtrip.log` (maintainer-held; see "About the evidence logs" at the top of this file). **Row A2 is now COMPLETE — both the install half and the seal-round-trip half are EXECUTED against a live cluster.** **DEFECT FIXED 2026-09-02, later the same day (TM-0346), and the fix re-proved on a second throwaway cluster:** the two flags are now on all SIX call sites (a sixth was found while fixing — `tools/mint-secrets.sh`'s own `--help` heredoc, which tells an air-gapped reader to run a bare `kubeseal --fetch-cert`). The fixed "## Sealing one" block, extracted from the working tree with `extract-block.sh --file` and run byte-for-byte, gives `grep -c '^kind: SealedSecret'` = 1, 1049 bytes, no plaintext leak, and a decrypted value equal to the canary; the same command with the flags stripped back out still gives 0 bytes. **Two claims on this row are corrected by that run.** (1) **`kubeseal` exits 1, not 0** — measured on kubeseal 0.30.0 / controller 0.39.1; the "exits 0 so exit-code checks pass" framing was never measured (P07 says so itself: "the exit code is not the assertion"). What fools a reader is the file the `>` redirect creates *before* kubeseal runs, not a false success. (2) The sealed file's **first line is `---`**, not `kind: SealedSecret`; assert with `grep -c '^kind: SealedSecret'`, which is what P07 already does and what the page's new success condition now states. Also observed: `helm install`'s own NOTES.txt prints the correct `--controller-name=`/`--controller-namespace=` invocation, so the documented install command was printing the fix to the operator's terminal all along. **This was P07's assertion run against the fixed bytes, not a run of P07** — P07 reads a git ref and the fix is uncommitted; P07 itself is unmodified, and its XFAIL is expected to be raised as a now-passing assertion on the first run after the commit. Evidence: run log `EVIDENCE-2026-09-02-TM0346-fix-proof.log` (maintainer-held; see "About the evidence logs" at the top of this file). Follow-up: TM-0350 (P07's two-attempt structure is obsolete once this lands). |
| A3 | The k3s install line exactly as `virtual-machines.md` gives it | `deployment/virtual-machines.md` | **PARTIAL / OPEN** | The harness installs k3s to build its own cluster, but from `provision/throwaway-cluster.sh`, **not** by extracting the page's line. That is the harness testing the harness. Until the provisioner extracts the documented line, this is OPEN, and the fact that k3s comes up is not evidence for the page. |
| A4 | `local-path` un-default, asserted **after a restart** | `administration/storage.md` §"Making it durable" | **EXECUTED 2026-09-04** | The procedure holds. Run against a throwaway carrying the full platform layer, 11 of 11 Applications Synced/Healthy, k3s `v1.36.4+k3s1`, charts `0.6.0`. Pre-state two defaults (`local-path` and `longhorn` both `true`) and no `.skip` file. After the page's two steps: `local-path` `false`, one default. **After `systemctl restart k3s`: still `false`. After a full node reboot: still `false`**, `local-path` still present, provisioner back up, one default. `resourceVersion` unchanged across both restarts, so no write landed on the object ... contrast the 09-01 measurement where the annotation flipped back. **The page's "Unverified against a Tockmox install" admonition is now discharged** and replaced with this measurement. **Two boundaries, kept:** the run was ONE server node, so the page's own "the file must exist on every server node" failure mode cannot occur there and is untested; and a k3s **upgrade** rather than a restart is untested. A third is worth naming because a reader may be in it: this run used the `install.md` Phase 3 ordering (`.skip` created after Longhorn's class existed), not the preparation-time ordering `fresh-install.md` §5 and `existing-cluster.md` Check 3 give. **Not a run of P03.** P03's node transport is `throwaway-cluster.sh exec`, which is SSH to a per-run key under `WORKDIR`; `/tmp` is cleared between sessions and pod-network mode has no inbound SSH path, so P03 exits 3. Step 1 was run through a privileged `nsenter` pod in the node's own mount namespace ... a different transport to the same node, not a substitute for the node-local step. P03 remains STAGED as a script. See TM-0287. |
| A5 | `install/tockmox-install.sh` end to end, to a syncing cluster | `deployment/install.md` | **PARTIAL ... EXECUTED 2026-09-02 against a live cluster, with a named boundary. NOT a path script yet.** | **All three stated preconditions are gone.** Sealed secrets: TM-0346, fixed and proved the same day. Site repository: TM-0247 made `--no-cluster` generate a complete one (24 files) with no kubectl. Repository credential: **there is no credential to design** ... `provision/site-repo-server.sh` serves the repo from a `git daemon` pod on a ClusterIP inside the cluster under test. Nothing leaves the cluster, nothing authenticates, and it dies with the throwaway. A credential that does not exist cannot expire or leak. **What ran:** installer generated the site with no cluster; site published in-cluster; `bootstrap/root.yaml` applied verbatim per the installer's own step 4; the root Application fanned out to **11 Applications, 11 of 11 Synced, 8 of 11 Healthy**. The 3 unhealthy were `CreateContainerConfigError` on Authentik server, Authentik worker and Grafana ... **the exact symptom `secrets.md` and `mint-secrets.sh` name for missing credentials, reproduced from a real install rather than reasoned about.** Then `tools/mint-secrets.sh` (carrying that morning's TM-0346 fix) minted 7 sealed credentials against the controller this same install created, `kubectl apply -f secrets/` per `install.md` line 635, and **all 7 decrypted into their four namespaces**. That is the whole documented chain, end to end, for the first time. **THE BOUNDARY, and it must not be reported away:** roughly ten minutes after the credentials landed the guest's kubelet stopped posting node status and the API went unreachable, so **this run never observed the three apps go Healthy.** The credentials they lacked are demonstrably present; whether that is sufficient is unproven. The cause of the node failure was not measured ... memory exhaustion on a single 8Gi node carrying all nine layers is consistent with `MemoryPressure Unknown` but was not confirmed (TM-0361). **Also not proven:** anything about the published `v0.6.0` tag. The product repo is PRIVATE, so source 1 of every multi-source Application failed with `authentication required: Repository not found` until the working tree was served in its place (TM-0360). **THE BOUNDARY IS NOW SETTLED, by a different run rather than by this one (2026-09-11).** A maintainer's single-node greenfield install, read 5h28m after it came up, read-only: `tockmox-identity` and `tockmox-observability` both report **Healthy**. So the credentials A5 minted are sufficient, and the three apps it could not wait for do come up. Two caveats travel with that: it is a DIFFERENT install on different hardware, not a re-run of A5, and the evidence is maintainer-held. **The same reading found something A5's numbers could not distinguish:** of 11 Applications, 11 Synced but only **9 Healthy** ... `tockmox-ai` reads `Progressing` permanently, because the LiteLLM migrations Job carries `ttlSecondsAfterFinished: 120` and the layer turns its Argo hook off, so Kubernetes deletes the completed Job and `selfHeal` recreates it every five minutes, indefinitely (thirteen recreations observed in 65 minutes of events). A5 read `8 of 11 Healthy` and attributed the gap entirely to missing credentials; part of it was this instead. **A single reading cannot tell a settled install from a cycling one**, which is why this row's eventual path script must assert the state across at least two reconcile periods rather than once. `site-apps` was also Degraded, for an unrelated and operator-side reason (a site secret not minted), which is the other thing a single reading cannot separate. **Why this is not STAGED or EXECUTED:** there is no path script. The run was driven by hand with a hand-written config, so it does not extract `install.md`'s blocks verbatim and does not satisfy rule 1. Writing P08 against `install.md` is the next block of work and the substrate now exists for it. **2026-09-11: the chain was driven END TO END BY HAND on a throwaway provisioned for the purpose, and it went further than the run above.** Provision at the Reference tier (8 cores / 24Gi / 250Gi) -> ArgoCD via `fresh-install.md` section 6 (chart 10.8.4, appVersion v3.5.2; both stated success conditions pass) -> sealed-secrets via section 7's OCI reference (chart 2.20.0, appVersion 0.40.0; both pass) -> `tockmox-install.sh --config` against a live cluster so the preflight ran -> `site-repo-server.sh` serving BOTH the product working tree and the site -> `kubectl apply -f bootstrap/root.yaml` -> eleven Applications. **The node did NOT die this time**, which was the boundary above: the layer set was still correct 8 hours later. **Still not EXECUTED by this inventory's own standard**, for the same reason as before ... there is no path script, the blocks were not extracted verbatim, and rule 1 is unmet. What it establishes is that the substrate and the whole chain work, so P08 is now writing a script against a proven path rather than designing one. **And one correction to a word this file has used loosely: "blocked" meant blocked for the nightly CI runner.** A session driving the provisioner by hand was never blocked, and recording it as blocked left the capability idle. Say who a blocker applies to. **Secrets were deliberately NOT minted on that run**, so 8 of 11 Applications were Healthy and three Degraded ... the same figure as above, from a different install, which makes it structural rather than incidental. Evidence: run log `EVIDENCE-2026-09-02-A5-installer-end-to-end.log` (maintainer-held; see "About the evidence logs" at the top of this file). |
| A6 | Profiles: minimal / reference / resilient / HA | `deployment/profiles.md` | **EXCEPTION** (partial) | Minimal and reference are single-node and in scope once A5 exists. **Resilient and HA are excepted: they need three or more nodes, and the test substrate provisions one.** What would change it: a second and third throwaway VM joined as agents, which the provisioner does not do today. This is a reason, not a difficulty. |
| A7 | Air-gap install vs connected | `deployment/airgap.md` | **EXCEPTION** | The air-gap proof is a step in the maintainer's release procedure (`RELEASING.md` § Operator gates, air-gap re-proof), run against a WAN-off lab and asserting on the artefact rather than on egress logs; the last run is the dated one `airgap.md` records. Folding it into this harness is duplication before it is coverage. What would change it: that RELEASING.md step becoming flaky or drifting from the page. **The update path (`airgap.md` step 8, TM-0120) is not covered by that re-proof either:** the re-proof is an install, and nothing in it moves a site from one release to the next, so step 8 is OPEN until a disconnected lab is taken across a release with it. |
| A8 | Immutable OS (MicroOS `transactional-update`, Talos extension, Flatcar iscsid) vs conventional (apt) | the immutable-OS table, which now lives in `deployment/existing-cluster.md` (this row used to cite `prerequisites.md`, which no longer carries it); the MicroOS mechanism is executed through `deployment/fresh-install.md` §2/§4/§4a and `operations/uninstall.md` §9 | **PARTIAL ... MicroOS EXECUTED 2026-09-23 by this harness, unattended. Talos and Flatcar remain EXCEPTION.** | **What the run establishes, and only this.** `throwaway-cluster.sh create` on image `tockmox-test/microos-cloud` now delegates to `provision/profiles/microos.sh` (TM-0715), which extracts nine blocks at a ref (eight from the pages, the timer hold transcribed and declared, TM-0722) and runs them in the guest as the unprivileged user across section 2's documented reboot. Run `tm0715-microos-06` against docs at `ec6ddbb`, evidence `Tockmox/EVIDENCE-2026-09-23-TM0715-microos-harness-run.log`: section 2's `transactional-update pkg install` exit 0 and staged snapshot #2, the reboot happened, the post-reboot `enable --now iscsid` exit 0, **section 2's success condition exit 0 (`active`, `/usr/sbin/iscsiadm`)**, section 4's exports block (with the page's YOU SUPPLY filled in and recorded) plus 4a's MicroOS one-node install, the `restorecon` block exit 0, and **section 4a's success condition exit 0 reading `Ready`** on k3s `v1.36.4+k3s1`, OS-IMAGE `openSUSE MicroOS`, confirmed from outside through the harness's own NodePort kubeconfig. Then `uninstall-proof`: k3s's uninstaller printed the page's quoted `Discarding snapshot` outcome verbatim, the page's own rule chose no reboot, and **uninstall.md §9's confirmation block printed all five `correct` lines** with the first line reading `@/.snapshots/2/snapshot`, as the page predicts. **What it does NOT establish.** Talos and Flatcar: never run. SLE Micro: a different image, never run. The three-node MicroOS shape (only the one-node block ran). Anything past a Ready bare node: no Tockmox chart, no Longhorn, so the table's `MountFlags=shared` note and TM-0628's metrics Services are untested here. `run.sh` paths on a MicroOS guest: now possible (`create` no longer refuses), not yet run. **How it was driven, stated rather than smoothed:** the operator's sandbox capped a command at about three minutes, so `create`'s wait was cut while the guest ran on alone and the new `await` verb collected the result; the guest's run itself was uninterrupted. **One page finding, not yet carded:** 4a's MicroOS install block exits **1** on a correct install (`Job for k3s.service failed`, the 203/EXEC the next block's `restorecon` fixes), and the page never tells a reader the first block is expected to report a failure. |

## B. The nine `documentation-steward` could-not-verify items

Delivered 2026-09-01 as TM-0290's first input: claims the rewritten
`deployment/prerequisites.md` makes that only execution can settle.

| # | Claim | Status | Evidence / reason |
|---|---|---|---|
| B1 | `helm install argocd argo/argo-cd --version <pinned>` succeeds; `applicationsets.argoproj.io` established | **EXECUTED 2026-09-02** | Same as A1b / `paths/P04-argocd-via-helm.sh`. |
| B2 | `kubectl apply --server-side --force-conflicts` completes | **STAGED** | A1c / `P02`. |
| B3 | `.skip` after local-path deploys, then the patch, then a k3s restart | **STAGED** | A4 / `P03`. |
| B4 | The immutable-OS table | **PARTIAL** ... MicroOS EXECUTED 2026-09-23, Talos and Flatcar EXCEPTION | A8. |
| B5 | `disable: [servicelb]` in `/etc/rancher/k3s/config.yaml` on an **existing** cluster, asserted across a restart | **OPEN** | Structurally identical to P03 ... an applied-vs-desired-state claim that only a restart settles ... and therefore cheap to add once P03 has run once. The strongest candidate for the fourth path script. |
| B6 | Success-condition commands the rewrite introduced | **13 counted (was "ten"), 3 EXECUTED, 7 EXCEPTION, 2 no-command, 0 remaining OPEN — plus one documentation defect found** | **The count itself was stale.** `grep -n 'Success condition' docs/deployment/fresh-install.md` on `main` returns **13** paragraphs, not ten — established before writing anything, per the run sheet's own warning not to trust the prior figure. Full line-by-line breakdown is in `paths/P06-argocd-metrics-success-condition.sh`'s header comment. Of the 13: **7 are node-local or need 3+ nodes** (iscsid/iscsiadm on every node; node-1 `Ready`; nodes 2/3 `Ready`, four-node only; the agent node, four-node only; the every-node MountFlags/Ready/no-traefik/version check; three nodes surviving a killed server, four-node only; the `.skip` file existing after a `touch`) — **EXCEPTION**, same shape as P03/B5: masquerade forbids inbound SSH and the substrate provisions one node, so these are recorded as written exceptions rather than forced or silently skipped. **2 state a condition with no accompanying command anywhere on the page** ("you hold a token ... scoped to one repository"; "you can write all four [site values] down") — flagged as human judgement, not buried, per rule 4; no artefact exists for a machine to assert on. **3 are already EXECUTED by earlier paths this session**: the ArgoCD "all three" condition (`paths/P04-argocd-via-helm.sh`, see B1/A1b) and the sealed-secrets `readyReplicas` + key-backup-count conditions (`paths/P05-sealed-secrets-install.sh`, see A2). **The 13th, the run sheet's own highest-risk pick, is now EXECUTED**: `kubectl -n argocd get svc \| grep metrics`, `paths/P06-argocd-metrics-success-condition.sh`, 2 assertions, both pass — (a) a stock install (fresh-install.md §6 block 2 only) shows **zero** metrics services, matching the page's own stated baseline; (b) after applying `administration/argocd.md`'s own documented values (`controller/server/repoServer.metrics.enabled: true`), the chart creates **exactly three** Services whose names contain `metrics` (`argocd-application-controller-metrics`, `argocd-repo-server-metrics`, `argocd-server-metrics`) — **the naming-convention risk the run sheet named does NOT materialise; the claim holds.** Evidence: run log `EVIDENCE-2026-09-02-B6-success-conditions.log` (maintainer-held; see "About the evidence logs" at the top of this file). **A different, real documentation defect was found in getting there, carded rather than fixed:** `fresh-install.md` §6 reads *"**Optional: turn on ArgoCD's metrics.** ... Success condition is `kubectl -n argocd get svc \| grep metrics` listing three services where a stock install has none,"* and links to `administration/argocd.md#its-metrics-are-off-until-you-turn-them-on`, which gives a fenced YAML values block (`controller.metrics.enabled`, `server.metrics.enabled`, `repoServer.metrics.enabled`) — but **no fenced command, in either section, ever applies those values.** No `helm upgrade`, no `-f values.yaml`, nothing: a reader who wants the page's own stated success condition has to invent the apply step themselves. P06's `helm upgrade argocd argo/argo-cd --version <resolved> --namespace argocd -f <values>` is harness-authored glue written for exactly that reason and flagged as such in the run log, not page text. **Suggested wording, not applied:** fence a `helm upgrade argocd argo/argo-cd --version <CHART_VERSION_FROM_ABOVE> --namespace argocd -f argocd-metrics-values.yaml` command in `administration/argocd.md` right after the values block (or add one line in `fresh-install.md` §6 pointing at it explicitly), so "Optional: turn on ArgoCD's metrics" is a procedure rather than values-plus-a-promise. Handed to `documentation-steward` for wording; not fixed here. **AMENDED 2026-09-17 (0.6.1, TM-0628 + TM-0708), and the row above is left as the record of the 2026-09-02 run.** The documentation defect is FIXED, by a better option than the one suggested above: the six metrics values went into section 6's own `helm install` block as `--set` flags, so a reader following the page top to bottom cannot miss them and no second page has to be opened. Three consequences for this row. **(1)** P06 no longer authors harness glue, and no longer extracts `administration/argocd.md`'s YAML at all. **(2)** Claim (a), "a stock install shows zero metrics services", is DROPPED rather than re-tested: the documented install no longer produces a stock install, so the page's baseline parenthetical is now a counterfactual that would need an undocumented command to reach. It is recorded under `does_not_prove`, not quietly deleted. So this row's "2 assertions, both pass" becomes **one assertion** ... the one the run sheet actually called risky. **(3) A latent defect in P06 itself was found while doing this and is the more serious finding.** P06 extracted the install with `--block 2`; the 2026-09-13 insertion of a reachability check at the top of section 6 shifted every ordinal, and while P04 was converted to `--containing` in that pass, **P06 was not**. `--block 2` has resolved to `helm repo add argo` since then, the same block P06's own CMD1 extracts, so this path has never executed the documented install. It never reported a false PASS only because the `paths` job needs a self-hosted runner that has never completed a run (every `executed-docs` run to date is cancelled, queued or pending) ... it would have bitten on the first real execution. Every extraction in P06 now names its command rather than its position, and the section canary gained `check_containing` so it asserts the same question the path asks instead of an ordinal nothing depends on. |
| B7 | `helm show chart oci://...` prints `version:` / `appVersion:` in the shape the page implies | **EXECUTED 2026-09-02** | `paths/B7-helm-show-chart-sealed-secrets.sh`, 1 assertion, pass. Needs no cluster: reads no `KUBECONFIG`, only network egress to the OCI registry. `fresh-install.md` §7 block 1 run verbatim; this run resolved `version: 2.19.3` / `appVersion: 0.39.1` (a moving tag, not pinned, same caveat as P04's chart read). The page carries no separately labelled "Success condition:" paragraph for this specific block, so the assertion is built from the block's own `grep -E '^(version|appVersion):'` filter plus the "YOU SUPPLY: the chart version from that output" prose immediately after it — both lines present and non-empty. Evidence: run log `EVIDENCE-2026-09-02-B7-helm-show-chart.log` (maintainer-held; see "About the evidence logs" at the top of this file). **Per-commit cadence candidacy held on rerun:** elapsed time was seconds, not the ~20 minutes the cluster-backed paths cost; the trade recorded in the run log is that the path's only external dependency is the OCI registry, so moving it per-commit would turn every commit red on a registry outage where a nightly job only misses one night. No workflow cadence was changed by this run. |
| B8 | The `--dry-run` transcript on the page, inherited and never re-captured | **OPEN** | The page also now asserts what that output does **not** cover, which is itself an untested claim about the installer. Testing the transcript and testing the claim about the transcript are two different jobs. |
| B9 | The ArgoCD 2.6 floor | **EXCEPTION** | Testing a floor means installing a release from 2023 and watching a multi-source Application fail to parse. The value is a sentence on a page; the cost is a second provisioner profile and an obsolete chart. What would change it: someone reporting that a current ArgoCD breaks the same way, which would mean the floor is not the real constraint. |

## C. Everything else

| # | Path | Status | Reason |
|---|---|---|---|
| C0 | `install.md`, every WORKSTATION block from "Set these once" to "Verify what Tockmox authored", as ONE zsh session | **EXECUTED 2026-09-14, against the working tree, on a throwaway.** `paths/P09-install-md-end-to-end.sh`, 22 steps, **47 assertions: 45 pass, 0 fail, 2 xfail.** Each block is extracted by content and fed to an interactive zsh on a pseudo-terminal as a bracketed paste (`lib/zsh-paste.py`), because that is the shell the page names as supported and three of its defects were invisible from bash; exports are carried between blocks, so the page's session model is what ran. Glue, all logged: a writable git remote at ONE URL that the workstation pushes to and the cluster clones from (served from inside the cluster under test, `--enable=receive-pack`, published on a NodePort and reached from the guest by hairpin); the product tree served beside it as the tag the operator would pin, which is why **nothing here is evidence about GitHub's copy or the published tag** (S04's ls-remote of the private repo is the first xfail); `$EDITOR` as a script writing the four YOU SUPPLY values; a git identity; the `read -rs` prompts (2c's token, the seal-target confirmation, the ntfy password twice) answered through the pty. **What it found, all fixed the same day and re-run:** 2a's bare `git init` names `master` on a stock git, `git push -u origin main` fails, and the page's success condition passed anyway (now `git init -b main` and a success condition that requires `## main...origin/main`); a transient GitHub 504 during `helm dependency build` wedged two Applications (platform, observability) behind a cached `ComparisonError` that automated sync never retries, and the troubleshooting index sent the reader to the credential entry (new entry, measured recovery); the page's illustrative policy render still read 32 NetworkPolicies (33, now pinned). **The second xfail is the readiness bar:** on a throwaway with no resolver for the internal domain, `tockmox-devops` stays Degraded on `lookup auth.<domain> ... no such host`, exactly the page's own expected-broken row 2, so the path records BLOCKED-by-environment for that one row rather than PASS or FAIL; the other eleven Applications reached Synced/Healthy and held. Conditional steps gate on the page's own reads (1d node count, 2c, the un-default gate) and the readings are logged. Absent its inputs (`TOCKMOX_P09_*`) the path declares BLOCKED and exits 0, so the nightly does not count it green or broken. The three writable-remote provisioning steps are still by hand this day; folding them into `site-repo-server.sh up --writable` and `throwaway-cluster.sh publish` is the next block. |
| C1 | Every other documented page | **ENUMERATED 2026-10-27, mostly OPEN** | Superseded by **section E** below: one row per page, with block counts re-measured by the scan `tools/doc-claims.txt` pins. This row used to say the remaining pages were unenumerated and "the next block of work on TM-0289"; that work is the table, and what is left is the OPEN rows in it. |
| C3 | `netpol-adversary.sh` ... what the shipped NetworkPolicy set actually admits and denies, measured from probe pods on a live cluster, both directions | **EXECUTED 2026-09-07 on a throwaway. LIVE-CLUSTER HARNESS, not a documented path: it asserts the policy artefacts, not a page.** Not run by `run.sh` (which globs `paths/P*.sh`); run it by hand after applying `charts/tockmox-policy` to a throwaway. Exits 2 (SKIPPED) with no cluster, with either probed namespace missing its `default-deny-ingress`, or on a CNI that does not enforce egress (proven first, every run). | TM-0273. Seven assertions on the shipped set: **5 pass, 0 fail, 2 xfail** (k3s v1.36.4+k3s1, embedded kube-router controller). The two xfails pin the card's known egress leaks (a plain `tockmox-ai` workload and a `tockmox-monitoring` workload both reach an external :443; the Open WebUI pod is contained) with `assert_artifact_xfail`, so the run goes RED the day a fix closes one ... the signal was tested by simulating fix 1 on the throwaway. That simulation also found a second companion allow fix 1 needs (intra-namespace egress, or Open WebUI -> LiteLLM breaks) that a by-hand pass had missed. **Extended 2026-09-29 for the TM-0273 fixes and NOT executed since** (the 0.6.2 gate owns the cluster): the fixed lines are hard assertions when `TOCKMOX_EXPECT_AI_EGRESS_DENY=1` / `TOCKMOX_EXPECT_NODE_SOURCES=1` declare the fix's values applied, plus a probe from an unguarded namespace to the object store's admin and S3 ports (the measured hole). The counts above describe the 2026-09-07 run, not the extended script. **Covers two of the six guarded namespaces**; the other four, the node-network and prometheus-scrape breadth rules, and the diagnostic identity are named in its `does_not_prove`. Evidence is maintainer-held (`EVIDENCE-2026-09-07-TM0273-harness-runs.log`). |
| C2 | `tools/check-blueprint-discovery.sh` ... Authentik discovered AND APPLIED every blueprint the chart ships | **RELEASE GATE, not a CI gate.** Runs during the greenfield gate install, never per-commit. | TM-0320, resolved 2026-09-02. It asserts a thing that only exists against a running, EMPTY Authentik, so no hermetic tier can carry it and no throwaway cluster in this harness installs the identity layer. It is wired into `RELEASING.md` and named in `administration/identity.md` as "a live cluster only, never CI". **The defect was that it was indistinguishable from a broken gate:** it exited 1 with no substrate, so the closing sweep `for f in tools/check-*.sh` reported it red in every ordinary session, which trains a reader to skim past red in `tools/`. It now exits **2** and says SKIPPED, so "could not run" and "found a defect" are different reports. It is listed here rather than only in its own header because this file, not a script comment, is where "what is covered, and by what" is answered. **What would move it into the executed tier:** a harness cluster that installs the identity layer, which is A5's territory, not this row's. |
| C4 | `tests/installer` ... the installer as a PROGRAM, both routes, against no cluster | **EXECUTED per-commit 2026-09-10. A THIRD TIER, not a documented path:** it asserts the installer's behaviour, not a page. 15 assertions, all pass, about two seconds, hermetic (`git` and `kubectl` stubbed). Listed here because this file, not a script comment, is where "what is covered, and by what" is answered. | Written after two defects no static gate could reach: the **interactive path could not complete** (an unbound variable used as a prompt default, fatal under `set -u`, eleven answers in ... and `README.md` lists that route FIRST, so the project's advertised first command was the broken one), and **`--no-cluster` did not skip the cluster preflight** when a cluster happened to answer. Both fixes proved by mutation: reverting each turns its own assertions red and not the others'. **What it does not prove:** that the generated site is correct against the charts, that the prompts ask the right questions, or anything downstream of the installer ... row **A5** still owns the end-to-end chain and is still PARTIAL. See `tests/installer/README.md`. |

## D. The TM-0290 handover: the two successor pages, section by section

`deployment/prerequisites.md` used to carry the install procedures. TM-0290's
rev-2 pass split it into three: it is now a **72-line signpost with zero fenced
blocks**, and the procedures live on `fresh-install.md` (46 bash blocks) and
`existing-cluster.md` (10). This section is TM-0290's step 7 ... **every
procedure section on both pages appears here**, whatever its status, so that a
section nobody has enumerated is impossible rather than merely unlikely.

**Enumerating is not testing.** Five of these eleven rows are OPEN or
EXCEPTION outright (D1, D2, D3, D8, D10) and three are STAGED (D4, D7, D9 ...
D9's second block stays OPEN). Recounted by hand 2026-09-04 when D7 and D9
gained a path script; this sentence said "six" before, and the state it
described counts to seven, so the figure was already off by one. The
point of the section is that the denominator is now visible: **7 of the 40
bash blocks on the two pages have been executed.** STAGED adds nothing to that
number. It belongs to TM-0289, not to TM-0290, and it is stated here so the
two cards cannot launder each other's progress.

| # | Section | Blocks | Status | Evidence / reason |
|---|---|---|---|---|
| D1 | `fresh-install.md` §2 Install the storage packages, on every node | 5 | **OPEN ... carried by TM-0302** | Four OS-specific blocks (MicroOS, Debian/Ubuntu, RHEL/Rocky, SLES/Leap) plus the success condition. Only MicroOS is fleet-verified, and it is verified in production rather than by this harness. The RHEL/Rocky block shipped with a **wrong package manager and a wrong package name**, found by a zero-context review and not by execution, which is the whole argument for TM-0302. Needs a guest per node OS. |
| D2 | `fresh-install.md` §3 Choose your cluster shape | 1 | **EXCEPTION** | The block is `hostnamectl` / `ip -4 addr show` / `timedatectl status`, and its stated conditions are "a UNIQUE hostname per node", "a static address or a DHCP reservation" and "NTP synchronised". Two of the three are **judgements about a fleet**, not assertions about a machine, and on a single-node throwaway "unique per node" is vacuously true ... a green run would mean nothing. `timedatectl` alone is assertable and is not worth a path on its own. What would change this: a multi-node harness, where uniqueness becomes a real property. |
| D3 | `fresh-install.md` §4 Install k3s | 15 | **PARTIAL/OPEN ... = row A3** | The largest section on the page and the one that installs the product's substrate. The harness's own guest installs k3s from cloud-init, **not from this page's line**, so the documented command has never run verbatim. |
| D4 | `fresh-install.md` §5 Stop k3s re-asserting its StorageClass default | 2 | **STAGED ... = row A4** | `paths/P03`. Node-local (`.skip` file on every server), so it needs in-guest execution that masquerade forbids. Unblocks with in-guest execution on the lab substrate. |
| D5 | `fresh-install.md` §6 Install ArgoCD | 3 | **EXECUTED ... = row A1b** | `paths/P04`, 3 assertions, all pass. Also P06 for the metrics condition. |
| D6 | `fresh-install.md` §7 Install sealed-secrets, with your own key | 4 | **EXECUTED ... = row A2** | `paths/P05` (install) and `paths/P07` (seal round trip). Blocks 1-3 re-run verbatim again on 2026-09-02 during the TM-0346 fix proof. |
| D7 | `existing-cluster.md` Check 1: version and node readiness | 1 | **STAGED 2026-09-04** | `paths/P08-existing-cluster-checks.sh`. `kubectl version` / `kubectl get nodes`, passing when the server is 1.30+ and every node is `Ready`; the script asserts the server minor floor and the deduplicated set of node `Ready` conditions. **Never run against a cluster.** Its citation stage has: extracted at `HEAD` and run with no cluster on 2026-09-04, it recorded `SUCCESS CONDITIONS STATED: 6` for the page with **no** "states none" divergence, which is the TM-0351 record ... this page labels every check "Passes when", and the first path written against it would have recorded six as zero under the old single-phrasing grep. Then it exited 3 (exception, no cluster). Was "one of the least-excusable OPEN rows in this file"; STAGED is a smaller claim than it sounds and the next nightly run is what moves it. |
| D8 | `existing-cluster.md` Check 2: exactly one LoadBalancer controller | 3 | **PARTIAL/OPEN** | Block 1 is read-only and assertable now. Blocks 2 and 3 write `/etc/rancher/k3s/config.yaml` and restart k3s on every server, which is **row B5** ... node-local, blocked on in-guest execution. Splitting the row would hide that one third of this check is reachable today. |
| D9 | `existing-cluster.md` Check 3: the default StorageClass | 2 | **STAGED 2026-09-04** (block 1) / **OPEN** (block 2) | `paths/P08-existing-cluster-checks.sh` runs block 1 (`kubectl get storageclass`) verbatim and counts `(default)` markers in its own output, expecting 1 on a stock k3s throwaway (`TOCKMOX_P08_EXPECTED_DEFAULT_COUNT` for the ordering where P03 has already un-defaulted `local-path`). **Never run against a cluster.** Block 2 is the node-local `.skip` touch and stays OPEN with D4/B5. The TM-0174 note stands: a stock install leaving **two** defaults was reported, and this is the first script that would read it. |
| D10 | `existing-cluster.md` Check 4: storage packages on every node | 2 | **OPEN** | Passes when every node prints `active` and a path for `iscsid`. In-guest execution, so it shares D1's and B5's blocker rather than having its own. |
| D11 | `existing-cluster.md` Checks 5 and 6: ArgoCD, sealed-secrets | 2 | **EXECUTED by reference** | Both cross-reference `fresh-install.md` §6 and §7 rather than documenting an independent route ... P05 verified that there is no TM-0299-shaped divergence here. Their own one-line checks are the same success conditions D5 and D6 already assert. |

---

## E. Every page with a bash block, one row each (TM-0289, 2026-10-27)

Rows A to D enumerate paths. This section enumerates **pages**, so that a page nobody has looked at is impossible rather than merely unlikely: 43 pages carry 465 fenced bash blocks (the scan `tools/doc-claims.txt` pins), one row each, largest first. The status is the page's best, not its average: **PARTIAL** means at least one block on it is covered by a row above and the rest are not.

**How far this gets.** 10 PARTIAL, 2 EXCEPTION, 31 OPEN of 43 pages. **No page is EXECUTED end to end.** Pages with at least one block executed against a live cluster by a path script or a recorded harness run: `install.md`, `fresh-install.md`, `argocd.md`, `secrets.md` and `storage.md`, and `uninstall.md` section 9 by way of A8's MicroOS run; `existing-cluster.md` and `backup-restore.md` have staged or in-product coverage only. That is the honest figure: every other page is OPEN, and the OPEN rows say what would cover them. A block-level count is not claimed beyond rows A to D, because most pages have never been enumerated block by block.

**What an EXCEPTION means here.** A written reason, tied to something the substrate cannot do (more than one node, a different hypervisor, a different OS, a Mac), plus what would change it. "Hard" is not a reason. The three rows marked *proposed* below (`ai-nodes.md`, the macOS and Windows blocks of `tls-and-trust.md`, the hypervisor walkthroughs of `virtual-machines.md`) are this inventory's suggestion and are for the maintainer to rule on; until then they are OPEN in effect.

| Page | Bash blocks | Status | Covered by, or why not |
|---|---|---|---|
| `deployment/install.md` | 50 | **PARTIAL** | C0 (`P09`) runs the WORKSTATION blocks from "Set these once" to "Verify what Tockmox authored" as one zsh session; A5 for the installer end to end. Blocks outside that range, and blocks added since 2026-09-14, are OPEN. Not yet re-run on the current tree. |
| `deployment/fresh-install.md` | 46 | **PARTIAL** | Section by section in **D1 to D6**: ArgoCD (P04) and sealed-secrets (P05, P07) EXECUTED, k3s line PARTIAL (A3), storage default STAGED (P03), the MicroOS variants EXECUTED 2026-09-23 (A8). Storage packages, the cluster-shape check and every node-local or three-node block are OPEN or EXCEPTION there. |
| `operations/uninstall.md` | 44 | **PARTIAL** | Section 9 (the transactional-OS teardown after a reboot) is part of A8's MicroOS run. The other sections are OPEN. A teardown is a candidate for a throwaway cluster, since destroying a throwaway is the point of one. |
| `operations/troubleshooting.md` | 34 | **OPEN** | Each block diagnoses a fault. Run on a healthy cluster it shows the command parses, not that it finds the fault, so a path needs the fault induced first. Needs a ruling: induce the cheap faults, and write an exception for the rest. |
| `deployment/upgrade.md` | 30 | **OPEN** | The upgrade leg of the release gate (RELEASING.md) exercises the upgrade on the maintainer's lab; which blocks it runs is not recorded per block, so coverage here is stated as OPEN. The Authentik database move and the rollback chain are marked not proven on the page. |
| `deployment/airgap.md` | 24 | **EXCEPTION** | Install: **A7**, the release procedure's air-gap re-proof on a WAN-off lab. Step 8, the update path, is **OPEN**: the re-proof is an install and moves no site between releases. |
| `operations/day-2.md` | 23 | **OPEN** | Independent routine tasks. Each is runnable on a throwaway cluster; none has a path. |
| `administration/tls-and-trust.md` | 19 | **OPEN** | The cluster-side rows were measured by hand on 2026-08-15 and re-confirmed on greenfield runs; the page says the per-OS trust installs were never run. Proposed: the Linux client blocks in a guest, and an EXCEPTION for macOS and Windows, which the substrate cannot host. |
| `deployment/upgrade-foundations.md` | 16 | **OPEN** | ArgoCD and k3s upgrades. Runnable on a throwaway; the k3s node steps share the in-guest blocker of B5. |
| `operations/sealed-secrets-key-escrow.md` | 14 | **OPEN** | Only the `age` round trip in step 1 has been run, by hand, on a laptop. The controller side shares P05's substrate. |
| `operations/backup-restore.md` | 13 | **PARTIAL** | Section 5's sequence is executed weekly by the product's own restore drill (a CronJob, not a CI job) for two databases, and by hand on dated labs. No harness path. The identity database's drill has not passed on a cluster. |
| `operations/second-site-dr.md` | 13 | **OPEN** | New 2026-10-27 (TM-0842). Execution on a throwaway second cluster is a lab exercise and is not done. |
| `deployment/existing-cluster.md` | 11 | **PARTIAL** | **D7 to D11**: Checks 1 and 3 STAGED (`P08`, never run), Checks 5 and 6 EXECUTED by reference, Checks 2 and 4 OPEN. |
| `administration/bring-your-own-ca.md` | 10 | **OPEN** | New 2026-10-27 (TM-0784). The card asks for a harness path (`P10`) that places an operator CA on a fresh cluster; none exists. |
| `administration/customising.md` | 10 | **OPEN** | Values, extension points and Kustomize patches. Render-time commands, runnable without a cluster. |
| `administration/secrets.md` | 9 | **PARTIAL** | "Sealing one" EXECUTED (`P07`, A2). The rest, including the full minting block, is OPEN. |
| `administration/values-contract.md` | 8 | **OPEN** | `jq` queries against a repository clone. No cluster needed, so a hermetic job is the cheap fit. |
| `deployment/time-sync.md` | 8 | **OPEN** | Node-local chrony configuration. Blocked on in-guest execution, like B5. |
| `administration/audit-logging.md` | 7 | **OPEN** | kube-apiserver flags on server nodes. Blocked on in-guest execution. |
| `deployment/virtual-machines.md` | 7 | **PARTIAL** | A3: the harness installs k3s, but not by extracting this page's line. The hypervisor walkthroughs are EXCEPTION candidates: the substrate is one hypervisor. |
| `deployment/verify.md` | 6 | **OPEN** | Signed-tag, checksum and SBOM checks. No cluster; runnable against a published tag in a hermetic nightly job. |
| `deployment/profiles.md` | 5 | **PARTIAL** | A6: minimal and reference are in scope once A5 exists; resilient and HA are EXCEPTION (three or more nodes). |
| `administration/ai-nodes.md` | 4 | **EXCEPTION** | Proposed. The procedure configures an Apple-silicon Mac; the substrate is an x86 guest on Harvester. Changes with a Mac runner. |
| `administration/api-endpoint.md` | 4 | **OPEN** | Meaningful only on a multi-node cluster; shares the three-node blocker. |
| `administration/external-integrations.md` | 4 | **OPEN** | Equipment around the cluster (firewall, DNS, switch). Mostly outside anything a throwaway cluster contains. |
| `agent-skills/airgap-prep/SKILL.md` | 4 | **OPEN** | Quotes `airgap.md`; follows it. |
| `operations/kube-bench.md` | 4 | **OPEN** | Opt-in CronJob on k3s with a privileged namespace. Runnable on a throwaway. |
| `usage/ai-plane.md` | 4 | **OPEN** | Needs a signed-in user and a model. |
| `usage/getting-started.md` | 4 | **OPEN** | Needs a browser sign-in; C0 ends before it. |
| `administration/capabilities.md` | 3 | **OPEN** | Render and read commands. |
| `administration/identity.md` | 3 | **OPEN** | Needs a running Authentik. |
| `administration/removing-an-application.md` | 3 | **OPEN** | Needs the Miniflux worked example installed. |
| `administration/storage.md` | 3 | **PARTIAL** | A4: the `local-path` un-default, held across a k3s restart and a node reboot, EXECUTED 2026-09-04. The other blocks are OPEN. |
| `agent-skills/edit-values-safely/SKILL.md` | 3 | **OPEN** | Render checks. |
| `deployment/registry.md` | 3 | **OPEN** | Registry configuration; shares airgap's mirror. |
| `administration/argocd.md` | 2 | **PARTIAL** | A1c: the server-side recovery EXECUTED (`P02`). The page's other block is OPEN. |
| `administration/configuration.md` | 2 | **OPEN** | Port-forward and render commands. |
| `administration/platform-management.md` | 2 | **OPEN** | Generator commands run from a checkout; no cluster. |
| `agent-skills/troubleshoot-install/SKILL.md` | 2 | **OPEN** | Collection commands; follows troubleshooting. |
| `administration/namespace-guard.md` | 1 | **OPEN** | New 2026-10-28 (TM-1223). One read that the policy and its binding exist; needs the policy layer synced on a cluster, so it shares the throwaway-cluster tier with `kube-bench.md`. |
| `administration/tockmox-ui.md` | 1 | **OPEN** | Seals one value for an install minted before 0.9.0. |
| `agent-skills/guided-install/SKILL.md` | 1 | **OPEN** | Quotes `install.md`. |
| `documentation-standard.md` | 1 | **OPEN** | One illustrative block. |

**Where a CI job runs these.** Two tiers exist: the per-commit hermetic selftest (`tests/executed-docs/selftest.sh`, no cluster) and the cluster job on a runner with access to the Harvester rig, nightly where that runner exists and dispatched for every release (RELEASING.md). Nothing in the OPEN rows is scheduled in either.

**Smallest next steps, ordered by cost.** (1) The pages whose blocks need no cluster (`values-contract.md`, `customising.md`, `verify.md`, `platform-management.md`, `capabilities.md`, `configuration.md`) can run in the hermetic tier. (2) `bring-your-own-ca.md` and `second-site-dr.md` are the two newest pages and each already names its lab clause. (3) `troubleshooting.md`, `day-2.md` and `uninstall.md` are 101 blocks between them and want a ruling on fault injection first.

---

## What the first run proved, beyond "the command fails"

**The old success condition passes over the broken install.** `prerequisites.md`
at v0.6.0-rc1 tells the reader to wait for `deployment/argocd-server` to become
available. On the cluster where the CRD apply had just failed, that deployment
reported `Available=True` — asserted, not assumed. So a reader following the
published page verbatim would have received the page's own green light on an
ArgoCD that cannot serve ApplicationSets, and Tockmox's generated Applications
are multi-source, so the failure would surface much later wearing a different
face.

This is the concrete form of the argument in the testing standard: **58 of the
59 objects applied.** A smoke test over "is the workload up?" is green across
this defect. Only an assertion naming the object that failed catches it.

`fresh-install.md` on `main` already asserts
`kubectl get crd applicationsets.argoproj.io` as one of three success
conditions, so the rewrite closed this. That is worth recording as a **verified
positive** rather than a defect: the executed run confirms the old condition
could not have caught it and the new one can.

**Environment, for parity:** guest Ubuntu 22.04.5, kernel 5.15, **amd64**,
k3s `v1.36.4+k3s1`, single node on KubeVirt. The harness runner is arm64, so the
architecture caveat applies to the runner and not to the cluster under test ...
which is a narrower caveat than this file previously carried.

## The blocking exception

**When this section was written, nothing in column A or B had run against a
cluster, and the credential was no longer the reason.** Since then the paths
listed as EXECUTED above have run; this section records the exception that
still blocks the rest.

### What now works, verified 2026-09-02

- A namespace-scoped credential reaches the KubeVirt API and its scope is
  correct in **both** directions ... it can do VM lifecycle in the disposable
  namespace and is refused everywhere else.
- The harness provisions a real VM: boot image imported, DataVolume `Succeeded`,
  PVC `Bound`, VMI `Running`, network attached.
- The guest-to-harness handoff path is proven **from the harness side**: the
  exact API call the guest is asked to make returns 201 when made by hand.

### What blocked it, and what the measurements turned out to be

Three things, and only the third is still open. All were diagnosed by reading
the guest's serial console over `virtctl`, which is why the RBAC widening that
made the console reachable was worth asking for.

**1. The boot disk was blank.** On this substrate an image-backed disk is bound
by the **per-image StorageClass**, the one whose parameters carry
`backingImage:`. The image-id annotation alone populates nothing. Using any
other class produces a `DataVolume: Succeeded`, a `PVC: Bound`, a
`VMI: Running` — and an empty volume with no operating system on it. The guest
emitted no console output at all because there was nothing to boot. The
provisioner now **derives** the class from the image and refuses a supplied
class that disagrees.

**2. The generated cloud-config was invalid YAML.** An inlined
`awk '{print \$4}'` inside a double-quoted scalar is an illegal escape.
cloud-init fails closed and silently. Fixed by moving every guest command into
`write_files` block scalars, and gated by parsing the document before boot.

**3. The segmented lab network did not forward.** Measured from inside the
guest: DHCP worked and handed out a lease, a default route existed, and the
gateway was `UNREACHABLE` — `http_code=000` to both the cluster API and the
public internet. That was a network build, not a harness problem, and it was
recorded as an exception rather than worked around.

**Resolved 2026-09-02.** The segment's DHCP service was handing out a router
option pointing at an address nothing owned, so guests had no first hop; every
other symptom followed from that. Corrected on the network, then re-measured
from inside a guest: the gateway is reachable, public egress returns `200`, and
a guest installs k3s end to end. **The cluster API remains unreachable from that
segment on purpose** — the segment is deliberately denied a route to the
management network, and a run where that call starts succeeding is a
containment regression rather than an improvement.

**Egress is not ingress, and only egress was fixed.** The harness still has no
inbound path to a guest on that segment: inbound there is per-host destination
NAT against fixed addresses, and a throwaway guest takes a lease that moves
every run. See *Still open* below.

**The route taken instead:** KubeVirt's default pod network with `masquerade`
binding (`TOCKMOX_VM_NETWORK=pod`). The guest NATs outbound and nothing reaches
in, so the harness reaches the guest's API through a `NodePort` Service on the
host. That Service, the port read-back and the kubeconfig rewrite are done by
`throwaway-cluster.sh create` itself (2026-09-02) rather than by hand: they are
setup, and the setup must not be the thing under test. `create` proves the
kubeconfig it emits reaches a `Ready` node before it returns, and `destroy`
removes the Service. Stated cost: masquerade gives the guest outbound access to the cluster's
pod network, which is broader than an isolated segment. It is a deliberate trade
and it should be revisited when the lab network forwards.

**`pod` became the default on 2026-09-04 (TM-0406).** The lab segment now
forwards outbound, and a guest on a bridged segment network was measured with a lease, a
default route and WAN (`get.k3s.io` 200) ... and still no route back to the
management network, so the `secret` handoff POST returns `http_code=000` and
`create` waits forever. A default that hangs from every harness host that cannot
route to the lab segment is not a default. `TOCKMOX_VM_NETWORK=NAMESPACE/SEGMENT`
remains the override for a host that can.

### Still open

**P03 needs inbound SSH to the guest**, because its first documented step is
node-local (`on EVERY k3s server node, sudo touch ...`). Masquerade forbids
inbound by construction. The segmented network now forwards outbound (see above)
but still offers no way IN to a disposable guest, because inbound there is
per-host address translation against fixed addresses and a throwaway takes a
lease that changes every run. Giving the guest a stable address is the unblock,
and it is a substrate decision rather than a harness one.

P03 therefore still records a **written exception** rather than a failure — a
topology that blocks SSH says nothing about whether the documented procedure
works. **The reason has narrowed, though, and that is worth stating rather than
leaving the old sentence in place:** it was "the network does not forward", and
it is now "a disposable guest has no stable address to publish". Same status,
different and much smaller blocker.

### The defect this already found, which is the point

The first two silent runs were a different problem entirely: the generated
cloud-config was **invalid YAML**, because an inlined `awk '{print \$4}'` inside
a double-quoted scalar is an illegal escape. cloud-init fails closed and
silently ... it ran nothing, surfaced no error the harness could see, and looked
exactly like a network fault.

Fixed by moving every guest command into `write_files` block scalars, which
process no escapes, and by making the provisioner **parse the document and
refuse to boot** if it is invalid or carries no `runcmd`. The harness now holds
itself to rule 1: assert on the artefact you generated before blaming the
environment you handed it to.

### The environment, for the record

The static-gate environment cannot host a cluster itself ... no container
runtime, no `/dev/kvm`, empty capability bounding set ... which is exactly why
an executed gate needs its own runner, and why `run.sh` now refuses rather than
carrying on when provisioning fails. An earlier version continued with an empty
`KUBECONFIG`, producing a page of connection-refused noise that read as a broken
cluster when the provisioner had in fact refused cleanly in one line.

This is recorded as an exception rather than left as an absence, which is the
rule the standard is built on. It is also, deliberately, the least comfortable
paragraph in this file: a harness that has never run is not a gate.

## What this harness does not prove, in general

Stated once here rather than repeated per row, and repeated per-run in the log
by `does_not_prove` in each path script:

- **Nothing about x86 openSUSE MicroOS.** The guest is an Ubuntu cloud image.
  The reference deployment is not. An immutable OS defers a package install to
  the next boot, which is why the k3s installer enables the service without
  starting it there ... a behaviour no run of this harness can see.
- **Nothing about multi-node anything.** One node means the failure modes that
  need two nodes cannot occur, so they are not being tested, they are being
  avoided.
- **Nothing about a path it does not contain.** The run summary reports what
  ran. This file reports what is covered. They are different numbers and the
  second one is smaller.
- **Nothing about the words of a page.** When execution finds a defect, this
  harness reports it and cards it. The fix belongs to `documentation-steward`.

## Pages that moved under a recorded run

Rows above are records of what was run on the day it was run, and are not
edited when a page later changes. This section says which pages have moved
since, so a reader does not mistake a stale line reference for a lost result.

- **2026-09-02, `docs/deployment/fresh-install.md` restructured** from a
  four-node path (3 servers + 1 agent) to **three servers with an optional
  worker node** at §4d. Affects the line references and the "FOUR-NODE ONLY"
  labels in **row B6** and in the header table of
  `paths/P06-argocd-metrics-success-condition.sh`; read those as
  "MULTI-NODE ONLY". **No verdict changes** ... the thirteen success conditions
  survive the restructure relabelled, and each row's EXCEPTION / COVERED /
  EXECUTED result stands. One page claim did change: §4f asserted "the
  remaining three nodes stay `Ready`", which was true only of the four-node
  shape, and now asserts every node except the one killed. The anchor
  `#4f-prove-a-four-node-cluster-survives-a-node-loss--four-nodes-only` is gone;
  it is now `#4f-prove-the-cluster-survives-a-node-loss--multi-node-only`.
  **Re-derive line numbers before trusting them.** The restructure also
  surfaced a defect it did not fix, carded as TM-0347: the HA tier promises an
  API VIP no page explains, and §4f can therefore fail on a healthy cluster and
  blame etcd for it.

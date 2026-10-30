# SPDX-License-Identifier: Apache-2.0
"""The model watcher's PR opener (REQ-0048 third ruling, TM-0930). Turns what the watcher found, and what the eval
runner has recorded, into pull requests on the site repo. Each PR is one of the two approvals, and still waits for
a person to merge it:

  admit     a candidate from the watcher's report -> catalog entry at stage candidate + <alias>-next (eval gateway)
  promote   a -next route whose comparative verdicts reach promotion.requiredPasses -> the alias moves
  evidence  files the eval runner wrote (result twins, verdict records) -> a PR that ADDS them under evals/. A third
            kind that is not an approval: it carries the proof the promotion PR will cite, and it never touches the
            values file (see "Evidence PRs" below)
  reject    a -next route a person (or the Compare page's Reject button) gave up on -> the route leaves the eval gateway
            and its catalog entry becomes `rejected` with the reason (TM-1262). Never planned by a run: it is asked for
  revert    a live alias that must go back to what it served before its last promotion -> the alias is re-pointed and the
            demoted build becomes `rejected` (TM-1262). Asked for by a person, or by the health watch

    python -m app.pr_opener CONFIG.yaml REPORT.json            # dry run: print the plan, touch nothing
    python -m app.pr_opener CONFIG.yaml REPORT.json --apply    # open the PRs

It builds every change with the same functions the Tockmox UI uses (models.propose, promote, change_doc) and runs
the same promotion gate before opening anything. It is a separate process from the UI, which stays write-free.

    python -m app.pr_opener reject CONFIG.yaml ALIAS-next --reason "why" [--apply]
    python -m app.pr_opener revert CONFIG.yaml ALIAS --reason "why" [--apply]

A reject or revert PR sits in the same lane as admit and promote: one model-lifecycle PR is open at a time (a reject or revert
refuses while another is open, and waits for none). It is built by models.reject / models.revert, so every refusal those raise
(a model that still serves a live alias, no previous route on record, a missing reason ...) is the opener's refusal, word for word.

What it will not do:
  - promote a hosted model: its data-class tags are a human choice made in the UI (REQ-0048 ruling 2);
  - write anything but the one values file it is pointed at, and only if that file holds nothing but the
    modelLifecycle and inferenceNodes blocks (it rewrites the whole file, so hand-written content would be lost);
  - talk to any host but the configured forge API, or follow a redirect;
  - open a PR while another model-lifecycle PR is open. Every PR rewrites the same file, and Jeff merges PRs in the
    order they appear, so they come one at a time: the next run plans against what was merged.
  - plan a candidate that modelLifecycle.inbox snoozed or dismissed (inbox.py), and it records the PR it opened for a
    candidate as `pr` in the report file, which the Inbox page links.

Evidence PRs (the third kind; AC-45.9, design 3.1 stage 7):

    python -m app.pr_opener evidence CONFIG.yaml DIR            # dry run
    python -m app.pr_opener evidence CONFIG.yaml DIR --apply    # open the PR

DIR is a tree whose paths are repo paths (DIR/evals/results/<node>/..., DIR/evals/verdicts/<run_id>.json). The opener
ADDS those files and nothing else: it refuses a path outside evals/, a file over 1 MiB, more than 200 files or 8 MiB,
an extension other than .json or .md, the values file, and any path that already exists with other bytes (a result is
never edited; identical bytes are skipped). It opens no PR for files that would fail CI: a verdict must be named
<run_id>.json, must cite its results as {path, sha256}, and each cited file must be in the same PR or already in the
repo with that sha256. An evidence PR does not wait on, or block, an admit or promotion PR: they touch different files.

Config, under modelLifecycle.watch.pullRequests:
  forge: github | forgejo        apiUrl: https://api.github.com | https://forgejo.example/api/v1
  repo: owner/name               baseBranch: main          valuesPath: site/values/models.yaml
  tokenEnv: TOCKMOX_BOT_TOKEN    maxOpen: 1                commitTrailers: ["Tockmox-Origin: model-watcher"]
  githubApp: {appId: 123456, privateKeyFile: /bot/private-key.pem}   # in-cluster: mint a one-hour, one-repo token
  verdictsRepoPath comes from modelLifecycle (default evals/verdicts).
"""
from __future__ import annotations

import base64
import datetime
import hashlib
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from urllib.parse import quote, urlsplit

import httpx
import yaml

from . import inbox as inboxmod
from . import models as ml
from . import nodes as nm
from . import results as rs

MAX_BYTES = 2 << 20
EVIDENCE_BRANCH = "tockmox/evidence/"
REJECT_BRANCH = "tockmox/reject/"
REVERT_BRANCH = "tockmox/revert/"
EVIDENCE_MAX_FILE = 1 << 20
EVIDENCE_MAX_FILES = 200
EVIDENCE_MAX_TOTAL = 8 << 20
EVIDENCE_EXT = (".json", ".md")
ADMIT_KINDS = ("quant", "successor", "frontier", "revision", "digest")


class Refused(ValueError):
    pass


# ---------------------------------------------------------------- the plan (pure)

@dataclass
class PRSpec:
    branch: str
    title: str
    body: str
    text: str                      # the whole new values file ("" for an evidence PR)
    kind: str                      # admit | promote | evidence | reject | revert
    subject: str                   # candidate id or alias
    files: dict = field(default_factory=dict)   # evidence PR only: repo path -> bytes to add


@dataclass
class Plan:
    prs: list = field(default_factory=list)
    skipped: list = field(default_factory=list)   # (what, why)


BRANCH_SLUG_MAX = 40


def branch_slug(s: str) -> str:
    """The branch-name part for a model id or alias. Short ones read as before; a long one is cut and given a
    hash of the WHOLE id, so two ids that agree in their first 40 characters never share a branch (a shared
    branch reads as "a PR for it is already open", and the second candidate would never be offered; TM-0939)."""
    import hashlib
    full = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "model"
    if len(full) <= BRANCH_SLUG_MAX:
        return full
    return full[: BRANCH_SLUG_MAX - 9].strip("-") + "-" + hashlib.sha256(s.encode("utf-8")).hexdigest()[:8]


def _values_text(doc, header):
    return "".join(f"# {h}\n" for h in header) + yaml.dump(doc, Dumper=nm._Dumper, sort_keys=False, width=120)


def check_values_file(doc) -> None:
    extra = sorted(set(doc or {}) - {"modelLifecycle", "inferenceNodes", "litellm"})
    if extra:
        raise Refused(f"the values file also holds {extra}; the opener rewrites the whole file, so point it at a file "
                      "that holds only modelLifecycle, inferenceNodes and the gateway's rolling annotation")
    lit = (doc or {}).get("litellm")
    if lit is not None and (not isinstance(lit, dict) or set(lit) != {"podAnnotations"}
                            or not isinstance(lit["podAnnotations"], dict)
                            or set(lit["podAnnotations"]) != {nm.ROLL_ANNOTATION}):
        raise Refused(f"the values file's litellm block holds more than podAnnotations.{nm.ROLL_ANNOTATION}; the opener "
                      "rewrites the whole file, so the site's other litellm values belong in another values file")


def plan(values: dict, report: dict | None, verdicts, open_branches=(), max_open=1, today=None) -> Plan:
    """What PRs this run would open. values: the machine-owned values file as it is on the base branch."""
    check_values_file(values)
    lc_raw, in_raw = values.get("modelLifecycle") or {}, values.get("inferenceNodes") or {}
    lc, inv = ml.parse(lc_raw), nm.parse_inventory(in_raw)
    skip = inboxmod.skipped_ids(inboxmod.parse(lc_raw.get("inbox")), today or datetime.datetime.now(datetime.timezone.utc))
    gw_list = [m for m in (in_raw.get("gateway") or {}).get("modelList") or [] if isinstance(m, dict)]
    gw_names = {str(m.get("model_name", "")) for m in gw_list}
    # an evidence PR adds files under evals/ and never touches the values file, so it does not hold up the one-at-a-time lane
    out, busy = Plan(), {b for b in open_branches if not b.startswith(EVIDENCE_BRANCH)}
    if busy:
        out.skipped.append(("this run", f"{len(busy)} model-lifecycle PR(s) already open ({', '.join(sorted(busy))}): one at a time"))
        return out
    header = ["Generated by the Tockmox model watcher. Machine-owned: edit through the Tockmox UI or a PR like this one."]

    def add(spec):
        if spec.branch in busy:
            out.skipped.append((spec.subject, "a PR for it is already open"))
        elif len(out.prs) >= max_open:
            out.skipped.append((spec.subject, f"over this run's limit of {max_open} PRs"))
        else:
            out.prs.append(spec)
            busy.add(spec.branch)

    # promotions first: they finish work already under way
    for r in inv.routes:
        if not r.alias.endswith(ml.NEXT):
            continue
        alias = r.alias[: -len(ml.NEXT)]
        try:
            new_lc, new_inv, notes = ml.promote(r.alias, verdicts, lc, inv)
        except (ml.LifecycleError, nm.NodeError) as e:
            out.skipped.append((r.alias, f"not promotable: {e}"))
            continue
        if ml.check_promotions(new_lc, new_inv):
            out.skipped.append((r.alias, "the promotion would fail the gate"))
            continue
        e = new_lc.by_model(r.model)
        ev = e.promotion["evidence"]
        body = (f"Promotes `{alias}` to `{r.model}` after {len(ev)} passing comparison(s) "
                f"(class {e.promotion['class']}, {e.promotion['required']} required).\n\n"
                + "".join(f"- `{x['runId']}` {x['date']} `{x['path']}` sha256 `{x['sha256'][:16]}...`\n" for x in ev)
                + "\n" + "".join(f"- {n}\n" for n in notes)
                + "\nMerging this is the second approval (REQ-0048): the model becomes callable on the production gateway.")
        add(PRSpec(f"tockmox/promote/{branch_slug(alias)}", f"Promote {alias} to {r.model}", body,
                   _values_text(ml.change_doc(lc_raw, in_raw, new_lc, new_inv), header), "promote", alias))

    for c in (report or {}).get("candidates", []) if report else []:
        try:
            cand = ml.parse_report({"schema": 1, "candidates": [c]}).candidates[0]
        except (ml.LifecycleError, KeyError, IndexError, TypeError, ValueError):
            out.skipped.append((str(c.get("id", "?")), "unreadable candidate"))
            continue
        if cand.kind not in ADMIT_KINDS:
            continue
        if cand.id in skip:
            out.skipped.append((cand.id, "snoozed or dismissed in modelLifecycle.inbox"))
            continue
        if cand.kind not in ("revision", "digest") and lc.by_model(cand.model):
            out.skipped.append((cand.id, "already in the catalog"))
            continue
        try:
            add_lc, add_inv, notes = ml.propose(cand, lc, inv, taken=gw_names, gateway=gw_list)
            new_lc = ml.merge(lc, add_lc)
            new_inv = nm.merge(inv, add_inv) if add_inv.routes else inv
        except (ml.LifecycleError, nm.NodeError, ValueError) as e:
            out.skipped.append((cand.id, str(e)))
            continue
        if cand.kind in ("quant", "successor") and not add_inv.routes:
            # nothing to compare it against, or every comparison slot is busy: a catalog-only PR would be noise
            out.skipped.append((cand.id, "no -next route could be added (" + "; ".join(notes) + "); admit it from the UI"))
            continue
        if cand.kind in ("revision", "digest") and ml.to_doc(new_lc) == ml.to_doc(lc):
            out.skipped.append((cand.id, "already recorded as pending"))
            continue
        if ml.check_promotions(new_lc, new_inv):
            out.skipped.append((cand.id, "the change would fail the gate"))
            continue
        hosted = cand.kind == "frontier"
        body = (f"{cand.detail}\n\n" + (f"Upstream: {cand.url}\n\n" if cand.url else "")
                + "".join(f"- {n}\n" for n in notes)
                + ("\nThe eval gateway serves hosted candidates from the catalog (stage candidate), with no data-class tags.\n" if hosted else "")
                + "\nMerging this is the first approval (REQ-0048): the candidate can be evaluated. No agent can call it.")
        verb = "Record a new build of" if cand.kind in ("revision", "digest") else "Admit for evaluation:"
        add(PRSpec(f"tockmox/admit/{branch_slug(cand.model)}", f"{verb} {cand.model}", body,
                   _values_text(ml.change_doc(lc_raw, in_raw, new_lc, new_inv), header), "admit", cand.id))
    return out


# ---------------------------------------------------------------- reject and revert PRs (TM-1262)

def _one_at_a_time(open_branches):
    busy = sorted(b for b in open_branches if not b.startswith(EVIDENCE_BRANCH))
    if busy:
        raise Refused(f"{len(busy)} model-lifecycle PR(s) already open ({', '.join(busy)}): one at a time. Merge or close it, then ask again")


def _change_spec(values, open_branches, build, kind, branch_prefix, subject, title, intro, closing):
    check_values_file(values)
    _one_at_a_time(open_branches)
    lc_raw, in_raw = values.get("modelLifecycle") or {}, values.get("inferenceNodes") or {}
    lc, inv = ml.parse(lc_raw), nm.parse_inventory(in_raw)
    try:
        new_lc, new_inv, notes = build(lc, inv)
    except (ml.LifecycleError, nm.NodeError) as e:
        raise Refused(str(e)) from None
    problems = ml.check_promotions(new_lc, new_inv)
    if problems:
        raise Refused("the change would fail the promotion gate: " + "; ".join(problems))
    header = ["Generated by the Tockmox model watcher's opener. Machine-owned: edit through the Tockmox UI or a PR like this one."]
    body = intro(lc, inv) + "\n\n" + "".join(f"- {n}\n" for n in notes) + "\n" + closing
    return PRSpec(f"{branch_prefix}{branch_slug(subject)}", title(lc, inv), body,
                  _values_text(ml.change_doc(lc_raw, in_raw, new_lc, new_inv), header), kind, subject)


def plan_reject(values: dict, alias_next: str, reason: str, when: str, open_branches=()) -> PRSpec:
    """The reject PR for `<alias>-next` (models.reject), or Refused with models.reject's own reason."""
    def model_of(inv):
        return next((r.model for r in inv.routes if r.alias == alias_next), alias_next)
    return _change_spec(
        values, open_branches, lambda lc, inv: ml.reject(alias_next, reason, when, lc, inv), "reject", REJECT_BRANCH, alias_next,
        lambda lc, inv: f"Reject {model_of(inv)} on {alias_next}",
        lambda lc, inv: f"Rejects `{model_of(inv)}` on `{alias_next}`.\n\nWhy: {reason.strip()[:400]}",
        "Merging this takes the candidate off the eval gateway and records the reason on its catalog entry. It moves no live alias, "
        "and the watcher offers the model again only at a different revision.")


def plan_revert(values: dict, alias: str, reason: str, when: str, open_branches=()) -> PRSpec:
    """The revert PR for a live alias (models.revert), or Refused with models.revert's own reason."""
    def model_of(inv):
        return next((r.model for r in inv.routes if r.alias == alias), alias)
    return _change_spec(
        values, open_branches, lambda lc, inv: ml.revert(alias, reason, when, lc, inv), "revert", REVERT_BRANCH, alias,
        lambda lc, inv: f"Revert {alias} from {model_of(inv)}",
        lambda lc, inv: f"Reverts `{alias}` from `{model_of(inv)}` to what it served before its last promotion.\n\nWhy: {reason.strip()[:400]}",
        "Merging this changes what the production gateway serves: the alias goes back to the previous model and the demoted build "
        "is marked rejected.")


def run_change(cfg, kind, subject, reason, forge, apply=False, when=None, log=print):
    """Open (or, without apply, only plan) the reject or revert PR for `subject`. Returns (spec, url)."""
    if kind not in ("reject", "revert"):
        raise Refused(f"{kind!r} is not a change this opener makes by request (reject or revert)")
    pr_cfg = (((cfg.get("modelLifecycle") or {}).get("watch") or {}).get("pullRequests")) or {}
    base, path = pr_cfg.get("baseBranch", "main"), pr_cfg.get("valuesPath", "")
    if not path:
        raise Refused("modelLifecycle.watch.pullRequests.valuesPath is not set")
    text, file_sha = forge.read_file(path, base)
    values = yaml.safe_load(text) or {}
    when = when or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    spec = (plan_reject if kind == "reject" else plan_revert)(values, subject, reason, when, forge.open_branches())
    if not apply:
        log(f"would open  {spec.branch}  {spec.title}")
        return spec, ""
    trailers = [str(t) for t in pr_cfg.get("commitTrailers") or []]
    url = forge.open_pr(base, spec, path, file_sha, spec.title + ("\n\n" + "\n".join(trailers) if trailers else ""))
    log(f"opened      {spec.branch}  {url}")
    return spec, url


# ---------------------------------------------------------------- evidence PRs (additive files under evals/)

def evidence_path_problem(path: str, values_path: str = "") -> str:
    """Why `path` may not be added by an evidence PR, or "". Everything is refused unless it is a short, plain,
    relative path under evals/ with a .json or .md extension, and not the values file."""
    if not ml.evidence_path_ok(path):
        return f"{path!r} is not a plain relative path under evals/"
    if values_path and path == values_path.strip("/"):
        return f"{path} is the values file: an evidence PR never touches it"
    if not path.endswith(EVIDENCE_EXT):
        return f"{path}: only {', '.join(EVIDENCE_EXT)} files are added"
    return ""


def plan_evidence(files: dict, existing, values_path: str = "", verdicts_dir: str = "evals/verdicts", label: str = "") -> PRSpec:
    """The evidence PR for `files` ({repo path: bytes}), or Refused with the first reason it cannot be opened.

    existing(path) -> bytes | None reads the file as it is on the base branch. Pure otherwise."""
    verdicts_dir = verdicts_dir.strip("/")
    if not files:
        raise Refused("no files to add")
    if len(files) > EVIDENCE_MAX_FILES:
        raise Refused(f"{len(files)} files: an evidence PR adds at most {EVIDENCE_MAX_FILES}")
    if sum(len(b) for b in files.values()) > EVIDENCE_MAX_TOTAL:
        raise Refused(f"over {EVIDENCE_MAX_TOTAL >> 20} MiB in total")
    new, skipped = {}, []
    for path in sorted(files):
        data = files[path]
        why = evidence_path_problem(path, values_path)
        if why:
            raise Refused(why)
        if not isinstance(data, (bytes, bytearray)) or len(data) > EVIDENCE_MAX_FILE:
            raise Refused(f"{path}: over {EVIDENCE_MAX_FILE >> 20} MiB")
        have = existing(path)
        if have is not None:
            if bytes(have) != bytes(data):
                raise Refused(f"{path} already exists with other contents: evidence is added, never edited (measure again under a new name)")
            skipped.append(path)
            continue
        new[path] = bytes(data)
    if not new:
        raise Refused("every file is already in the repo with these contents")
    sha_of = lambda b: hashlib.sha256(b).hexdigest()  # noqa: E731

    def resolve(path):
        if path in files:
            return bytes(files[path])
        return existing(path)

    runs, twins = [], 0
    for path, data in new.items():
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            raise Refused(f"{path} is not UTF-8 text") from None
        if path.endswith(".json") and path.startswith(verdicts_dir + "/"):
            try:
                v = ml.parse_verdict(text, path)
            except ml.LifecycleError as e:
                raise Refused(f"{path}: not a verdict record ({e})") from None
            if path != f"{verdicts_dir}/{v.run_id}.json":
                raise Refused(f"{path}: a verdict file is named <run_id>.json (this one is run {v.run_id})")
            if v.warnings:
                raise Refused(f"{path}: new evidence must be hashed: " + "; ".join(v.warnings))
            for x in v.results:
                got = resolve(x["path"])
                if got is None:
                    raise Refused(f"{path} cites {x['path']}, which is neither in this PR nor in the repo")
                if sha_of(got) != x["sha256"]:
                    raise Refused(f"{path} cites {x['path']} with a sha256 that does not match the file")
            runs.append(v.run_id)
        elif path.endswith(".json") and '"capability-result/1"' in text[:4096]:
            try:
                r = rs.parse(text, path)
            except rs.ResultError as e:
                raise Refused(f"{path}: not a valid capability-result/1 ({e})") from None
            if path != rs.repo_path(r):
                raise Refused(f"{path}: a result of this run belongs at {rs.repo_path(r)}")
            twins += 1
    names = ", ".join(sorted(new)[:8]) + (f" and {len(new) - 8} more" if len(new) > 8 else "")
    tag = label or (runs[0] if runs else hashlib.sha256("\n".join(sorted(new)).encode()).hexdigest()[:10])
    body = (f"Adds {len(new)} file(s) of evidence under evals/ ({twins} result twin(s), {len(runs)} verdict record(s)).\n\n"
            + "".join(f"- `{p}` sha256 `{sha_of(new[p])[:16]}...`\n" for p in sorted(new)[:40])
            + (f"\nAlready in the repo, skipped: {', '.join(skipped)}.\n" if skipped else "")
            + "\nNothing here changes a model, a route or the values file. CI recomputes every sha256 a verdict cites "
              "(verdict_check); a promotion PR can cite these verdicts once this is merged.")
    return PRSpec(f"{EVIDENCE_BRANCH}{branch_slug(tag)}", f"Evidence: {names}"[:120], body, "", "evidence", tag, new)


def run_evidence(cfg, files, forge, apply=False, log=print):
    lc_cfg = cfg.get("modelLifecycle") or {}
    pr_cfg = ((lc_cfg.get("watch") or {}).get("pullRequests")) or {}
    base, path = pr_cfg.get("baseBranch", "main"), pr_cfg.get("valuesPath", "")
    spec = plan_evidence(files, lambda p: forge.read_bytes(p, base), path, str(lc_cfg.get("verdictsRepoPath", "evals/verdicts")))
    if spec.branch in forge.open_branches():
        log(f"skipped     {spec.branch}: a PR for it is already open")
        return spec, ""
    if not apply:
        log(f"would open  {spec.branch}  {spec.title}")
        return spec, ""
    trailers = [str(t) for t in pr_cfg.get("commitTrailers") or []]
    url = forge.open_files_pr(base, spec, "Evidence" + ("\n\n" + "\n".join(trailers) if trailers else ""))
    log(f"opened      {spec.branch}  {url}")
    return spec, url


def read_tree(root: str) -> dict:
    """{repo path: bytes} for every file under root, refusing symlinks and anything over the per-file cap before reading it."""
    out = {}
    root = os.path.realpath(root)
    for dp, dn, fns in os.walk(root):
        for fn in fns:
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            if os.path.islink(full):
                raise Refused(f"{rel} is a symlink")
            if os.path.getsize(full) > EVIDENCE_MAX_FILE:
                raise Refused(f"{rel}: over {EVIDENCE_MAX_FILE >> 20} MiB")
            if len(out) >= EVIDENCE_MAX_FILES:
                raise Refused(f"more than {EVIDENCE_MAX_FILES} files")
            with open(full, "rb") as fh:
                out[rel] = fh.read()
    return out


# ---------------------------------------------------------------- GitHub App auth (in-cluster, no long-lived token)

def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def app_jwt(app_id: str, key_pem: bytes, now: int | None = None) -> str:
    """The short JWT a GitHub App signs with its private key (RS256), valid 9 minutes, backdated 60 s for clock skew."""
    import time
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    t = int(now if now is not None else time.time())
    head = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64url(json.dumps({"iat": t - 60, "exp": t + 540, "iss": str(app_id)}, separators=(",", ":")).encode())
    key = serialization.load_pem_private_key(key_pem, password=None)
    sig = key.sign(f"{head}.{body}".encode(), padding.PKCS1v15(), hashes.SHA256())
    return f"{head}.{body}.{_b64url(sig)}"


def app_installation_token(api_url, repo, app_id, key_pem, transport=None, now=None) -> str:
    """Exchange the App's JWT for an installation token scoped to `repo` only, with only the two permissions the
    opener needs. The token lives about an hour and exists only in this process (the ADR-0031 pattern: a
    sealed App key in the cluster, never a long-lived token)."""
    u = urlsplit(api_url)
    if u.scheme != "https" or not u.hostname:
        raise Refused("apiUrl must be an https:// URL")
    if not re.match(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", repo or ""):
        raise Refused("repo must be owner/name")
    c = httpx.Client(timeout=20.0, follow_redirects=False, transport=transport, trust_env=True,
                     headers={"Authorization": f"Bearer {app_jwt(app_id, key_pem, now)}", "Accept": "application/vnd.github+json",
                              "User-Agent": "tockmox-model-watcher"})
    base = api_url.rstrip("/")
    r = c.get(f"{base}/repos/{repo}/installation")
    if r.status_code != 200:
        raise Refused(f"the App is not installed on {repo} (HTTP {r.status_code})")
    inst = r.json()["id"]
    r = c.post(f"{base}/app/installations/{inst}/access_tokens",
               json={"repositories": [repo.split("/", 1)[1]], "permissions": {"contents": "write", "pull_requests": "write"}})
    if r.status_code != 201:
        raise Refused(f"no installation token (HTTP {r.status_code})")
    return r.json()["token"]


# ---------------------------------------------------------------- the forge (the only I/O)

class Forge:
    """GitHub REST or Forgejo/Gitea API v1. Talks only to the configured API host, never follows a redirect,
    caps every answer, and sends the token only there."""

    def __init__(self, kind, api_url, repo, token, transport=None, timeout=20.0):
        if kind not in ("github", "forgejo"):
            raise Refused("forge must be github or forgejo")
        u = urlsplit(api_url)
        if u.scheme != "https" or not u.hostname:
            raise Refused("apiUrl must be an https:// URL")
        if not re.match(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", repo or ""):
            raise Refused("repo must be owner/name")
        self.kind, self.base, self.host, self.repo = kind, api_url.rstrip("/"), u.hostname, repo
        auth = f"Bearer {token}" if kind == "github" else f"token {token}"
        self.c = httpx.Client(timeout=timeout, follow_redirects=False, transport=transport, trust_env=True,
                              headers={"Authorization": auth, "Accept": "application/json", "User-Agent": "tockmox-model-watcher"})
        self.calls = []

    def _req(self, method, path, body=None, ok=(200, 201)):
        url = f"{self.base}/repos/{self.repo}{path}"
        if urlsplit(url).hostname != self.host:
            raise Refused("refusing a request to another host")
        self.calls.append((method, path))
        r = self.c.request(method, url, json=body)
        if len(r.content) > MAX_BYTES:
            raise Refused("answer over the cap")
        if r.status_code not in ok:
            raise httpx.HTTPStatusError(f"{method} {path}: HTTP {r.status_code}", request=r.request, response=r)
        return r.json() if r.content else {}

    def base_sha(self, branch):
        if self.kind == "github":
            return self._req("GET", f"/git/ref/heads/{quote(branch, safe='')}")["object"]["sha"]
        return self._req("GET", f"/branches/{quote(branch, safe='')}")["commit"]["id"]

    def read_file(self, path, ref):
        d = self._req("GET", f"/contents/{quote(path)}?ref={quote(ref, safe='')}")
        return base64.b64decode(d.get("content") or "").decode("utf-8"), d.get("sha", "")

    def read_bytes(self, path, ref):
        """The file's bytes at ref, or None when it does not exist."""
        try:
            d = self._req("GET", f"/contents/{quote(path)}?ref={quote(ref, safe='')}")
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return None
            raise
        if isinstance(d, list):
            raise Refused(f"{path} is a directory in the repo")
        return base64.b64decode(d.get("content") or "")

    def open_files_pr(self, base, spec: PRSpec, message):
        """A branch that ADDS spec.files (a PUT with no sha fails if the path exists, so an existing file can never be
        overwritten even if it appeared since the plan), and a PR for it. A failure part-way removes the branch."""
        if self.kind == "github":
            self._req("POST", "/git/refs", {"ref": f"refs/heads/{spec.branch}", "sha": self.base_sha(base)})
        else:
            self._req("POST", "/branches", {"new_branch_name": spec.branch, "old_branch_name": base})
        try:
            for path, data in sorted(spec.files.items()):
                self._req("PUT", f"/contents/{quote(path)}", {"message": f"{message}: add {path}", "branch": spec.branch,
                                                              "content": base64.b64encode(data).decode()})
            pr = self._req("POST", "/pulls", {"title": spec.title, "head": spec.branch, "base": base, "body": spec.body})
        except Exception:
            try:
                if self.kind == "github":
                    self._req("DELETE", f"/git/refs/heads/{quote(spec.branch, safe='')}", ok=(200, 204))
                else:
                    self._req("DELETE", f"/branches/{quote(spec.branch, safe='')}", ok=(200, 204))
            except Exception:  # noqa: BLE001 - the original failure is the one to report
                pass
            raise
        return pr.get("html_url") or pr.get("url") or ""

    def list_dir(self, path, ref):
        try:
            d = self._req("GET", f"/contents/{quote(path)}?ref={quote(ref, safe='')}")
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return []
            raise
        return [x["path"] for x in d if isinstance(x, dict) and x.get("type") == "file"] if isinstance(d, list) else []

    def open_branches(self):
        return {p["head"]["ref"] for p in self._req("GET", "/pulls?state=open&per_page=100")
                if isinstance(p, dict) and p.get("head", {}).get("ref", "").startswith("tockmox/")}

    def open_pr(self, base, spec: PRSpec, path, file_sha, message):
        if self.kind == "github":
            self._req("POST", "/git/refs", {"ref": f"refs/heads/{spec.branch}", "sha": self.base_sha(base)})
        else:
            self._req("POST", "/branches", {"new_branch_name": spec.branch, "old_branch_name": base})
        self._req("PUT", f"/contents/{quote(path)}", {"message": message, "branch": spec.branch, "sha": file_sha,
                  "content": base64.b64encode(spec.text.encode("utf-8")).decode()})
        pr = self._req("POST", "/pulls", {"title": spec.title, "head": spec.branch, "base": base, "body": spec.body})
        return pr.get("html_url") or pr.get("url") or ""


def load_verdicts(forge, root, ref, limit=500):
    out, bad = [], []
    for p in sorted(forge.list_dir(root, ref))[:limit]:
        if not p.endswith(".json"):
            continue
        try:
            text, _ = forge.read_file(p, ref)
            out.append(ml.parse_verdict(text, p))
        except (ml.LifecycleError, UnicodeDecodeError) as e:
            bad.append(f"{p}: {e}")
    return out, bad


def run(cfg, report, forge, apply=False, env=os.environ, log=print):
    lc_cfg = cfg.get("modelLifecycle") or {}
    pr_cfg = ((lc_cfg.get("watch") or {}).get("pullRequests")) or {}
    base, path = pr_cfg.get("baseBranch", "main"), pr_cfg.get("valuesPath", "")
    if not path:
        raise Refused("modelLifecycle.watch.pullRequests.valuesPath is not set")
    text, file_sha = forge.read_file(path, base)
    values = yaml.safe_load(text) or {}
    verdicts, bad = load_verdicts(forge, str(lc_cfg.get("verdictsRepoPath", "evals/verdicts")).strip("/"), base)
    if bad:
        # an unreadable verdict could be the fail that resets a count: no promotions this run
        log(f"{len(bad)} verdict file(s) unreadable, so no promotion is planned: " + "; ".join(bad[:3]))
        verdicts = None
    p = plan(values, report, verdicts if verdicts is not None else [], forge.open_branches(), int(pr_cfg.get("maxOpen", 1)))
    if verdicts is None:
        p.prs = [x for x in p.prs if x.kind != "promote"]
    trailers = [str(t) for t in pr_cfg.get("commitTrailers") or []]
    opened = []
    for spec in p.prs:
        if not apply:
            log(f"would open  {spec.branch}  {spec.title}")
            continue
        url = forge.open_pr(base, spec, path, file_sha, spec.title + ("\n\n" + "\n".join(trailers) if trailers else ""))
        opened.append(url)
        log(f"opened      {spec.branch}  {url}")
    for what, why in p.skipped:
        log(f"skipped     {what}: {why}")
    return p, opened


def record_pr_links(report_path, links):
    """Write each opened admit PR's URL into the report as `pr` on its candidate (https only), so the Inbox page can link it.
    Atomic; a report that cannot be rewritten is reported and left alone."""
    try:
        with open(report_path, encoding="utf-8") as fh:
            doc = json.load(fh)
        for c in doc.get("candidates") or []:
            if links.get(c.get("id"), "").startswith("https://"):
                c["pr"] = links[c["id"]]
        d = os.path.dirname(os.path.abspath(report_path))
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".report-")
        with os.fdopen(fd, "w") as fh:
            json.dump(doc, fh, indent=1)
        os.replace(tmp, report_path)
        return True
    except (OSError, ValueError) as e:
        print(f"could not record the PR link in {report_path}: {e}", file=sys.stderr)
        return False


def _forge_from(cfg, pr_cfg):
    token = os.environ.get(pr_cfg.get("tokenEnv", "TOCKMOX_BOT_TOKEN"), "")
    app = pr_cfg.get("githubApp") or {}
    if not token and app and pr_cfg.get("forge", "github") == "github":
        # appId + the path of the mounted private key (a sealed Secret): mint a one-hour, one-repo token
        with open(app["privateKeyFile"], "rb") as fh:
            token = app_installation_token(pr_cfg.get("apiUrl", "https://api.github.com"), pr_cfg.get("repo", ""),
                                           str(app["appId"]), fh.read())
    if not token:
        print(f"no token in ${pr_cfg.get('tokenEnv', 'TOCKMOX_BOT_TOKEN')} and no githubApp configured", file=sys.stderr)
        return None
    return Forge(pr_cfg.get("forge", "github"), pr_cfg.get("apiUrl", "https://api.github.com"), pr_cfg.get("repo", ""), token)


def main(argv):
    argv = list(argv)
    reason = ""
    if "--reason" in argv:
        i = argv.index("--reason")
        reason = argv[i + 1] if i + 1 < len(argv) else ""
        del argv[i:i + 2]
    args = [a for a in argv[1:] if not a.startswith("--")]
    apply = "--apply" in argv
    evidence = bool(args) and args[0] == "evidence"
    change = args[0] if args and args[0] in ("reject", "revert") else ""
    if evidence or change:
        args = args[1:]
    if len(args) != 2:
        print("usage: python -m app.pr_opener CONFIG.yaml REPORT.json [--apply]\n"
              "       python -m app.pr_opener evidence CONFIG.yaml DIR [--apply]\n"
              "       python -m app.pr_opener reject CONFIG.yaml ALIAS-next --reason WHY [--apply]\n"
              "       python -m app.pr_opener revert CONFIG.yaml ALIAS --reason WHY [--apply]", file=sys.stderr)
        return 2
    cfg = yaml.safe_load(open(args[0], encoding="utf-8")) or {}
    pr_cfg = (((cfg.get("modelLifecycle") or {}).get("watch") or {}).get("pullRequests")) or {}
    if not pr_cfg.get("enabled", False):
        print("the PR opener is off (modelLifecycle.watch.pullRequests.enabled is false)", file=sys.stderr)
        return 0
    forge = _forge_from(cfg, pr_cfg)
    if forge is None:
        return 2
    if evidence:
        try:
            run_evidence(cfg, read_tree(args[1]), forge, apply)
        except Refused as e:
            print(f"refused: {e}", file=sys.stderr)
            return 1
        return 0
    if change:
        try:
            run_change(cfg, change, args[1], reason, forge, apply)
        except Refused as e:
            print(f"refused: {e}", file=sys.stderr)
            return 1
        return 0
    report = json.load(open(args[1], encoding="utf-8")) if os.path.exists(args[1]) else None
    p, opened = run(cfg, report, forge, apply)
    if apply and opened and report is not None:
        record_pr_links(args[1], {spec.subject: url for spec, url in zip(p.prs, opened) if spec.kind == "admit"})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

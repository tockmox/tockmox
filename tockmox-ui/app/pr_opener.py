# SPDX-License-Identifier: Apache-2.0
"""The model watcher's PR opener (REQ-0048 third ruling, TM-0930). Turns what the watcher found, and what the eval
runner has recorded, into pull requests on the site repo. Each PR is one of the two approvals, and still waits for
a person to merge it:

  admit     a candidate from the watcher's report -> catalog entry at stage candidate + <alias>-next (eval gateway)
  promote   a -next route whose comparative verdicts reach promotion.requiredPasses -> the alias moves

    python -m app.pr_opener CONFIG.yaml REPORT.json            # dry run: print the plan, touch nothing
    python -m app.pr_opener CONFIG.yaml REPORT.json --apply    # open the PRs

It builds every change with the same functions the Tockmox UI uses (models.propose, promote, change_doc) and runs
the same promotion gate before opening anything. It is a separate process from the UI, which stays write-free.

What it will not do:
  - promote a hosted model: its data-class tags are a human choice made in the UI (REQ-0048 ruling 2);
  - write anything but the one values file it is pointed at, and only if that file holds nothing but the
    modelLifecycle and inferenceNodes blocks (it rewrites the whole file, so hand-written content would be lost);
  - talk to any host but the configured forge API, or follow a redirect;
  - open a PR while another model-lifecycle PR is open. Every PR rewrites the same file, and Jeff merges PRs in the
    order they appear, so they come one at a time: the next run plans against what was merged.

Config, under modelLifecycle.watch.pullRequests:
  forge: github | forgejo        apiUrl: https://api.github.com | https://forgejo.example/api/v1
  repo: owner/name               baseBranch: main          valuesPath: site/values/models.yaml
  tokenEnv: TOCKMOX_BOT_TOKEN    maxOpen: 1                commitTrailers: ["Tockmox-Origin: model-watcher"]
  githubApp: {appId: 123456, privateKeyFile: /bot/private-key.pem}   # in-cluster: mint a one-hour, one-repo token
  verdictsRepoPath comes from modelLifecycle (default evals/verdicts).
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys
from dataclasses import dataclass, field
from urllib.parse import quote, urlsplit

import httpx
import yaml

from . import models as ml
from . import nodes as nm

MAX_BYTES = 2 << 20
ADMIT_KINDS = ("quant", "successor", "frontier", "revision", "digest")


class Refused(ValueError):
    pass


# ---------------------------------------------------------------- the plan (pure)

@dataclass
class PRSpec:
    branch: str
    title: str
    body: str
    text: str                      # the whole new values file
    kind: str                      # admit | promote
    subject: str                   # candidate id or alias


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


def plan(values: dict, report: dict | None, verdicts, open_branches=(), max_open=1) -> Plan:
    """What PRs this run would open. values: the machine-owned values file as it is on the base branch."""
    check_values_file(values)
    lc_raw, in_raw = values.get("modelLifecycle") or {}, values.get("inferenceNodes") or {}
    lc, inv = ml.parse(lc_raw), nm.parse_inventory(in_raw)
    gw_names = {str(m.get("model_name", "")) for m in (in_raw.get("gateway") or {}).get("modelList") or [] if isinstance(m, dict)}
    out, busy = Plan(), set(open_branches)
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
        if cand.kind not in ("revision", "digest") and lc.by_model(cand.model):
            out.skipped.append((cand.id, "already in the catalog"))
            continue
        try:
            add_lc, add_inv, notes = ml.propose(cand, lc, inv, taken=gw_names)
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


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    apply = "--apply" in argv
    if len(args) != 2:
        print("usage: python -m app.pr_opener CONFIG.yaml REPORT.json [--apply]", file=sys.stderr)
        return 2
    cfg = yaml.safe_load(open(args[0], encoding="utf-8")) or {}
    pr_cfg = (((cfg.get("modelLifecycle") or {}).get("watch") or {}).get("pullRequests")) or {}
    if not pr_cfg.get("enabled", False):
        print("the PR opener is off (modelLifecycle.watch.pullRequests.enabled is false)", file=sys.stderr)
        return 0
    token = os.environ.get(pr_cfg.get("tokenEnv", "TOCKMOX_BOT_TOKEN"), "")
    app = pr_cfg.get("githubApp") or {}
    if not token and app and pr_cfg.get("forge", "github") == "github":
        # appId + the path of the mounted private key (a sealed Secret): mint a one-hour, one-repo token
        with open(app["privateKeyFile"], "rb") as fh:
            token = app_installation_token(pr_cfg.get("apiUrl", "https://api.github.com"), pr_cfg.get("repo", ""),
                                           str(app["appId"]), fh.read())
    if not token:
        print(f"no token in ${pr_cfg.get('tokenEnv', 'TOCKMOX_BOT_TOKEN')} and no githubApp configured", file=sys.stderr)
        return 2
    report = json.load(open(args[1], encoding="utf-8")) if os.path.exists(args[1]) else None
    forge = Forge(pr_cfg.get("forge", "github"), pr_cfg.get("apiUrl", "https://api.github.com"), pr_cfg.get("repo", ""), token)
    run(cfg, report, forge, apply)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

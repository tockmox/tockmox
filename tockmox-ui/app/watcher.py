# SPDX-License-Identifier: Apache-2.0
"""The model watcher (REQ-0048): look upstream, write what is new to a report. Never changes anything.

    python -m app.watcher CONFIG.yaml REPORT.json

A separate process from the UI, run on a schedule (a CronJob, TM-0930), OFF unless the operator
turns it on: it is the one Tockmox component that reaches the internet on its own, so it does so
only to the hosts in WATCH_HOSTS, never follows a redirect, caps every answer, sends no
identifiers, and carries a provider key only to that provider. Air-gapped sites leave it off.

Sources, all read-only:
  Hugging Face   GET  /api/models/<repo>                        sha, lastModified (revision)
                 GET  /api/models?filter=base_model:<base>       other quants of the same base
                 GET  /api/models?author=<org>&sort=createdAt    newer releases (successors)
  Ollama         HEAD registry.ollama.ai/v2/library/<m>/manifests/<tag>   the build's digest
  OpenRouter     GET  /api/v1/models                              keyless cross-vendor list (+expiration_date)
  Anthropic      GET  /v1/models                                  when a key is configured
  OpenAI         GET  /v1/models                                  when a key is configured (+shutdown_date)
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import sys
import re
import tempfile
from urllib.parse import quote, urlsplit

import httpx
import yaml

from . import models as ml

WATCH_HOSTS = frozenset({"huggingface.co", "registry.ollama.ai", "openrouter.ai", "api.anthropic.com", "api.openai.com"})
MAX_BYTES = 4 << 20
UA = "tockmox-model-watcher"


class Refused(ValueError):
    pass


class Fetcher:
    def __init__(self, timeout=10.0, transport=None, hosts=WATCH_HOSTS):
        self.c = httpx.Client(timeout=timeout, follow_redirects=False, transport=transport, trust_env=True,
                              headers={"User-Agent": UA})
        self.hosts = hosts
        self.calls = []

    def _check(self, url):
        u = urlsplit(url)
        if u.scheme != "https" or u.hostname not in self.hosts:
            raise Refused(f"{u.hostname}: not a watched host")

    def json(self, url, headers=None):
        self._check(url)
        self.calls.append(("GET", url))
        with self.c.stream("GET", url, headers=headers or {}) as r:
            if r.status_code != 200:
                raise httpx.HTTPStatusError(f"HTTP {r.status_code}", request=r.request, response=r)
            buf = b""
            for ch in r.iter_bytes():
                buf += ch
                if len(buf) > MAX_BYTES:
                    raise Refused("answer over the cap")
        return json.loads(buf)

    def head(self, url, headers=None):
        self._check(url)
        self.calls.append(("HEAD", url))
        r = self.c.head(url, headers=headers or {})
        if r.status_code != 200:
            raise httpx.HTTPStatusError(f"HTTP {r.status_code}", request=r.request, response=r)
        return r.headers


def _why(e):
    if isinstance(e, httpx.HTTPStatusError):
        return str(e)
    if isinstance(e, httpx.TimeoutException):
        return "timed out"
    if isinstance(e, httpx.ConnectError):
        return "unreachable"
    return f"{type(e).__name__}: {e}"[:200]


def run(cfg: dict, f: Fetcher, env=os.environ, now=None) -> dict:
    lc = ml.parse(cfg.get("modelLifecycle") or {})
    w = (cfg.get("modelLifecycle") or {}).get("watch") or {}
    quant_authors = tuple(w.get("quantAuthors") or ("mlx-community", "lmstudio-community", "unsloth", "bartowski"))
    sources, cands, gaps = {}, [], []

    def note(name, ok, reason=""):
        prev = sources.get(name)
        if prev and not prev["ok"]:
            return                     # one failure in a source marks the whole source
        sources[name] = {"ok": ok, "reason": reason}

    hf = "https://huggingface.co/api/models"
    for e in lc.catalog:
        if e.stage == "retired":
            continue
        # review finding: an entry that tracks nothing, or tracks revisions with nothing pinned, made no request
        # and still let the source read "ok", so the page said everything was current
        if e.source.kind in ("huggingface", "ollama"):
            if not e.track:
                gaps.append(f"{e.id}: tracks nothing")
                continue
            if "revision" in e.track and not e.source.revision:
                gaps.append(f"{e.id}: tracks revisions but has no pinned revision to compare")
            # lab finding F13 (2026-10-08): `track: [quants]` with no baseModel made no request at all and the source
            # still read "ok" with no gap, so the page said the model was current when nothing had been looked at
            if e.source.kind == "huggingface" and "quants" in e.track and not e.base_model:
                gaps.append(f"{e.id}: tracks quants but has no baseModel to find other quantisations of")
        try:
            if e.source.kind == "huggingface":
                asked = False
                info = f.json(f"{hf}/{quote(e.source.ref, safe='/')}") if ("revision" in e.track and e.source.revision) else None
                asked = info is not None or asked
                sib = []
                if "quants" in e.track and e.base_model:
                    asked = True
                    # one query per trusted publisher: sorted globally, the base's most recent derivatives are
                    # someone's fine-tunes and the trusted quants fall off the page (lab finding 2026-10-07)
                    for qa in quant_authors:
                        sib += f.json(f"{hf}?author={quote(qa)}&filter={quote('base_model:quantized:' + e.base_model, safe=':/')}&limit=20")
                org = (e.base_model or e.source.ref).split("/")[0]
                newer = f.json(f"{hf}?author={quote(org)}&sort=createdAt&direction=-1&limit=100") if "successors" in e.track else []
                asked = asked or "successors" in e.track
                cands += ml.detect_hf(e, info, sib, newer, quant_authors)
                if asked:                      # a source answered only if it was asked something
                    note("huggingface", True)
            elif e.source.kind == "ollama":
                name, _, tag = e.source.ref.partition(":")
                if not re.match(r"^[a-z0-9][a-z0-9._/-]{0,127}$", name) or not re.match(r"^[A-Za-z0-9._-]{0,128}$", tag):
                    raise Refused(f"{e.source.ref!r} is not an Ollama name:tag")
                path = quote(name if "/" in name else f"library/{name}", safe="/")
                h = f.head(f"https://registry.ollama.ai/v2/{path}/manifests/{tag or 'latest'}",
                           {"Accept": "application/vnd.docker.distribution.manifest.v2+json"})
                digest = h.get("ollama-content-digest") or h.get("docker-content-digest") or ""
                cands += ml.detect_ollama(e, digest, h.get("ollama-push-time", ""))
                note("ollama", True)
        except Exception as ex:  # noqa: BLE001 - a failed source is recorded, never silent
            note(e.source.kind if e.source.kind in ("huggingface", "ollama") else "other", False, f"{e.id}: {_why(ex)}")

    known = {}
    # the site config keeps the gateway's list at inferenceNodes.gateway.modelList (review finding: only a
    # top-level key was read, so on a real site every hosted model looked new)
    gml = list(cfg.get("gatewayModelList") or []) + list(((cfg.get("inferenceNodes") or {}).get("gateway") or {}).get("modelList") or [])
    for m in gml:
        full = str((m.get("litellm_params") or {}).get("model", ""))
        if "/" in full and not (m.get("litellm_params") or {}).get("api_base"):
            p, mid = full.split("/", 1)
            known.setdefault(p, set()).add(mid)
    for e in lc.catalog:
        if e.source.kind == "hosted" and "/" in e.source.ref:
            p, mid = e.source.ref.split("/", 1)
            known.setdefault(p, set()).add(mid)
    prov = w.get("providers") or {}
    for name, pc in prov.items():
        pc = pc or {}
        try:
            if name == "openrouter":
                d = f.json("https://openrouter.ai/api/v1/models")
                listed = [{"id": m["id"], "created": m.get("created"), "shutdown": m.get("expiration_date")} for m in d.get("data", [])]
            elif name == "anthropic":
                key = env.get(pc.get("keyEnv", "ANTHROPIC_API_KEY"), "")
                if not key:
                    note(name, False, "no key configured")
                    continue
                d = f.json("https://api.anthropic.com/v1/models?limit=1000", {"x-api-key": key, "anthropic-version": "2023-06-01"})
                listed = [{"id": m["id"], "created": m.get("created_at")} for m in d.get("data", [])]
            elif name == "openai":
                key = env.get(pc.get("keyEnv", "OPENAI_API_KEY"), "")
                if not key:
                    note(name, False, "no key configured")
                    continue
                d = f.json("https://api.openai.com/v1/models", {"Authorization": f"Bearer {key}"})
                listed = [{"id": m["id"], "created": m.get("created"), "shutdown": m.get("shutdown_date")} for m in d.get("data", [])]
            else:
                note(name, False, "unknown provider")
                continue
            cands += ml.detect_frontier(name, listed, known.get(name, set()), pc.get("allow"))
            note(name, True)
        except Exception as ex:  # noqa: BLE001
            note(name, False, _why(ex))

    seen, uniq = set(), []
    for c in cands:
        if c.id not in seen:
            seen.add(c.id)
            uniq.append(c)
    ts = (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"schema": 1, "generatedAt": ts, "sources": sources, "gaps": gaps,
            "candidates": [{"id": c.id, "kind": c.kind, "subject": c.subject, "model": c.model, "source": c.source.as_dict(),
                            "detail": c.detail, "url": c.url, **({"sizeGiB": c.size_gib} if c.size_gib is not None else {}),
                            "when": str(c.when or "")} for c in uniq]}


def write_atomic(path, doc):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".report-")
    with os.fdopen(fd, "w") as fh:
        json.dump(doc, fh, indent=1)
    os.replace(tmp, path)


def main(argv):
    cfg = yaml.safe_load(open(argv[1], encoding="utf-8")) or {}
    w = (cfg.get("modelLifecycle") or {}).get("watch") or {}
    if not w.get("enabled", False):
        print("watcher is off (modelLifecycle.watch.enabled is false); nothing fetched", file=sys.stderr)
        return 0
    doc = run(cfg, Fetcher(timeout=float(w.get("timeoutSeconds", 10))))
    write_atomic(argv[2], doc)
    bad = [k for k, v in doc["sources"].items() if not v["ok"]]
    print(f"{len(doc['candidates'])} candidate(s); sources ok: {sorted(k for k, v in doc['sources'].items() if v['ok'])}"
          + (f"; FAILED: {bad}" if bad else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

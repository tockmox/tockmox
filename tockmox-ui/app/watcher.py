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

Inbox (TM-1258): a candidate whose id is in modelLifecycle.inbox.dismissed, or in .snoozed with a date still ahead, is left out of
the report (and so is not sized). A retiring hosted model carries `replacement` when the provider's listing names one or the site
does (watch.providers.<name>.replacements: {retiring id: replacement id}); a candidate keeps the `pr` link the PR opener recorded
for it in the previous report.

Sizes (AC-48.14, fit v2), for every catalogued Hugging Face model, every Hugging Face candidate in this report and
every operator-named seed (modelLifecycle.recommend.seeds), at most watch.sizes.maxRepos (default 80) per run:
  Hugging Face   GET  /api/models/<repo>/revision/<sha>?blobs=true   file sizes at the pinned build (unpinned: the
                                                                     repo's current build, whose sha is recorded)
                 GET  /<repo>/resolve/<sha>/config.json              layers, kv heads, head size, experts
The answer is the report's `sizes` section: weights bytes, KV bytes per token, fixed per-sequence state, licence. The
UI has no egress (AC-48.10), so this is the only place those numbers can come from. Same fixed hosts, no redirect, same
cap. config.json answers with one 307 to /api/resolve-cache/ on the same host, followed once (Fetcher.json); a redirect
to any other host, a CDN included, is a gap, never followed.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import sys
import re
import tempfile
from urllib.parse import quote, urljoin, urlsplit

import httpx
import yaml

from . import fit as fitmod
from . import inbox as inboxmod
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

    def _read(self, url, headers):
        self.calls.append(("GET", url))
        with self.c.stream("GET", url, headers=headers or {}) as r:
            if r.status_code in (301, 302, 303, 307, 308):
                return r.status_code, r.headers.get("location", ""), b""
            if r.status_code != 200:
                raise httpx.HTTPStatusError(f"HTTP {r.status_code}", request=r.request, response=r)
            buf = b""
            for ch in r.iter_bytes():
                buf += ch
                if len(buf) > MAX_BYTES:
                    raise Refused("answer over the cap")
        return 200, "", buf

    def json(self, url, headers=None, follow_cache_hop=False):
        """GET and parse. Never follows a redirect, with ONE named exception (follow_cache_hop, used only for a
        file at /<repo>/resolve/<sha>/<file>): Hugging Face answers that with a 307 to
        /api/resolve-cache/models/... on the SAME host (measured 2026-10-21), so the hop is followed once, and only when
        the Location is https, on the very host asked, under that one path prefix. A redirect to any other host,
        a CDN included, is refused like every other redirect: the fence is the host list, and a hop that stays
        inside it does not widen it."""
        self._check(url)
        status, loc, buf = self._read(url, headers)
        if status != 200:
            u0 = urlsplit(url)
            hop = urlsplit(urljoin(url, loc)) if loc else None
            if not (follow_cache_hop and hop and hop.scheme == "https" and hop.hostname == u0.hostname
                    and hop.path.startswith("/api/resolve-cache/")):
                raise Refused(f"redirect to {(hop.hostname or '?') if hop else '?'} not followed")
            self._check(urljoin(url, loc))
            status, _loc, buf = self._read(urljoin(url, loc), headers)
            if status != 200:
                raise Refused("a second redirect is not followed")
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


# ---------------------------------------------------------------- sizes (fit v2)

_SHARD = re.compile(r"^(?P<stem>.+?)-\d{5}-of-\d{5}\.gguf$")
_FLOAT_DTYPES = {"BF16", "F16", "F32", "F8_E4M3", "F8_E5M2", "F64"}


def _file_size(x):
    n = x.get("size")
    if not isinstance(n, int):
        n = (x.get("lfs") or {}).get("size")
    return n if isinstance(n, int) and n >= 0 else None


def _norm(q):
    return re.sub(r"[^a-z0-9]", "", q.lower())


def sum_weights(siblings, quant: str = "") -> tuple[int | None, int, str, list]:
    """(bytes, files counted, format, notes) from a repo's file list. Safetensors: the top-level shards (a
    `consolidated` copy beside sharded files is the same weights twice, so it is dropped). GGUF: one quantisation
    only, matched to the catalog entry's `quant` (sharded files are one group); a repo with several quantisations
    and no match is NOT summed, because the sum is no file anyone loads."""
    notes = []
    files = [(str(x.get("rfilename", "")), _file_size(x)) for x in siblings if isinstance(x, dict)]
    st = [(n, sz) for n, sz in files if n.endswith(".safetensors") and "/" not in n]
    if len(st) < len([1 for n, _ in files if n.endswith(".safetensors")]):
        notes.append("safetensors in sub-folders were not counted")
    gg = [(n, sz) for n, sz in files if n.endswith(".gguf") and "mmproj" not in n.lower()]
    if st:
        if any(not n.startswith("consolidated") for n, _ in st):
            dropped = [n for n, _ in st if n.startswith("consolidated")]
            if dropped:
                notes.append("a consolidated.safetensors copy of the same weights was not counted")
            st = [(n, sz) for n, sz in st if not n.startswith("consolidated")]
        if any(sz is None for _, sz in st):
            return None, len(st), "safetensors", notes + ["a weights file has no size in the answer"]
        if gg:
            notes.append("GGUF files beside the safetensors were not counted")
        return sum(sz for _, sz in st), len(st), "safetensors", notes
    if gg:
        groups = {}
        for n, sz in gg:
            m = _SHARD.match(n)
            groups.setdefault(m.group("stem") if m else n[:-5], []).append((n, sz))
        if quant:
            q = _norm(quant)
            hit = {k: v for k, v in groups.items() if q and q in _norm(k)}
        else:
            hit = groups if len(groups) == 1 else {}
        if len(hit) == 1:
            files_ = next(iter(hit.values()))
            if any(sz is None for _, sz in files_):
                return None, len(files_), "gguf", notes + ["a weights file has no size in the answer"]
            return sum(sz for _, sz in files_), len(files_), "gguf", notes
        notes.append(f"{len(groups)} GGUF quantisations in the repo and " + (f"none matches quant {quant!r}" if quant else "the catalog names none") +
                     ": weights not summed")
        return None, 0, "gguf", notes
    return None, 0, "", notes + ["no safetensors or GGUF weights in the repo"]


def _license(info):
    card = info.get("cardData") if isinstance(info.get("cardData"), dict) else {}
    lic = card.get("license")
    if isinstance(lic, list):
        lic = lic[0] if lic else ""
    if not lic:
        for t in info.get("tags") or []:
            if isinstance(t, str) and t.startswith("license:"):
                lic = t[len("license:"):]
                break
    return str(lic or "").lower()[:80]


def _eval_results(info):
    """Self-reported results from the model card's model-index: a HINT, labelled as one wherever it is shown."""
    out = []
    card = info.get("cardData") if isinstance(info.get("cardData"), dict) else {}
    for mi in (card.get("model-index") or [])[:2]:
        for r in (mi.get("results") or [])[:20] if isinstance(mi, dict) else []:
            ds = (r.get("dataset") or {}).get("name", "") if isinstance(r, dict) else ""
            for m in (r.get("metrics") or [])[:3] if isinstance(r, dict) else []:
                if isinstance(m, dict) and isinstance(m.get("value"), (int, float)) and len(out) < 6:
                    out.append({"name": str(m.get("name") or m.get("type") or "")[:60], "value": f"{m['value']:g}", "dataset": str(ds)[:60]})
    return out


def size_record(f: "Fetcher", ref: str, revision: str, quant: str, now: str) -> tuple[fitmod.SizeRecord, list]:
    """Read one repo's files and config at `revision` (or its current build). Returns the record and the reasons any
    part could not be read; a part that failed is None in the record, never zero."""
    gaps = []
    base = f"https://huggingface.co/api/models/{quote(ref, safe='/')}"
    info = f.json(f"{base}/revision/{quote(revision, safe='')}?blobs=true" if revision else f"{base}?blobs=true")
    sha = str(info.get("sha") or revision or "")
    size, nfiles, fmt, notes = sum_weights(info.get("siblings") or [], quant)
    tags = [t for t in (info.get("tags") or []) if isinstance(t, str)]
    if info.get("library_name") == "mlx" or "mlx" in tags:
        fmt = "mlx" if fmt in ("safetensors", "") else fmt
    kv = {}
    if sha and re.match(r"^[0-9a-f]{40}$", sha):
        try:
            cfg = f.json(f"https://huggingface.co/{quote(ref, safe='/')}/resolve/{sha}/config.json", follow_cache_hop=True)
            kv = fitmod.kv_from_config(cfg)
            notes += kv.get("notes", [])
        except Exception as ex:  # noqa: BLE001 - recorded, and the record keeps its weights
            notes.append(f"config.json: {_why(ex)}")
            gaps.append(f"{ref}: config.json not read ({_why(ex)}), so no KV figure")
    else:
        notes.append("no commit sha in the answer, so config.json was not read")
    total_b, active_b = fitmod.params_from_name(ref)
    st = info.get("safetensors") if isinstance(info.get("safetensors"), dict) else {}
    if not total_b and st.get("total") and set((st.get("parameters") or {}).keys()) <= _FLOAT_DTYPES:
        total_b = st["total"] / 1e9
    gated = bool(info.get("gated"))
    rec = fitmod.SizeRecord(
        ref, sha, size, nfiles, kv.get("kv_bytes_per_token"), kv.get("full_attention_layers"), kv.get("total_layers"),
        kv.get("recurrent_state_bytes"), kv.get("sliding_window_bytes"), kv.get("sliding_window_tokens"),
        round(total_b, 2) if total_b else None, active_b, bool(kv.get("moe") or active_b), _license(info),
        str(info.get("pipeline_tag") or "")[:60], fmt, gated, tuple(_eval_results(info)), tuple(notes[:12]), now)
    if size is None:
        gaps.append(f"{ref}: weights not sized ({'; '.join(notes[-1:]) or 'no size'})")
    return rec, gaps


def collect_sizes(cfg: dict, lc, cands, f: "Fetcher", now: str) -> tuple[dict, list]:
    """The report's `sizes` and `sizeGaps`. Targets, in priority order: catalog entries (at their pinned revision),
    this report's Hugging Face candidates, the operator's seeds. One record per repo."""
    w = ((cfg.get("modelLifecycle") or {}).get("watch") or {}).get("sizes") or {}
    if w.get("enabled", True) is False:
        return {}, []
    cap = int(w.get("maxRepos", 80))
    want, quant = {}, {}

    def add(ref, rev, q=""):
        if ref not in want and ml.HF_REPO.match(ref or ""):
            want[ref] = rev or ""
            quant[ref] = q

    for e in lc.catalog:
        if e.stage != "retired" and e.source.kind == "huggingface":
            add(e.source.ref, e.source.revision, e.quant)
    for c in cands:
        if c.source.kind == "huggingface" and c.kind in ("quant", "successor", "revision"):
            add(c.source.ref, c.source.revision)
    for sd in ((cfg.get("modelLifecycle") or {}).get("recommend") or {}).get("seeds") or []:
        if isinstance(sd, dict):
            add(str(sd.get("ref", "")), str(sd.get("revision", "") or ""), str(sd.get("quant", "") or ""))
    sizes, gaps = {}, []
    for i, (ref, rev) in enumerate(want.items()):
        if i >= cap:
            gaps.append(f"{len(want) - cap} more repo(s) were not sized: over watch.sizes.maxRepos ({cap})")
            break
        try:
            rec, g = size_record(f, ref, rev, quant.get(ref, ""), now)
            sizes[ref] = rec.as_dict()
            gaps += g
        except Exception as ex:  # noqa: BLE001
            gaps.append(f"{ref}: not sized ({_why(ex)})")
    return sizes, gaps


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
                listed = [{"id": m["id"], "created": m.get("created"), "shutdown": m.get("expiration_date"),
                           "replacement": m.get("replacement")} for m in d.get("data", [])]
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
            cands += ml.detect_frontier(name, listed, known.get(name, set()), pc.get("allow"), pc.get("replacements") or {})
            note(name, True)
        except Exception as ex:  # noqa: BLE001
            note(name, False, _why(ex))

    stamp = now or datetime.datetime.now(datetime.timezone.utc)
    skip = inboxmod.skipped_ids(inboxmod.parse((cfg.get("modelLifecycle") or {}).get("inbox")), stamp)
    seen, uniq = set(), []
    for c in cands:
        if c.id not in seen and c.id not in skip:
            seen.add(c.id)
            uniq.append(c)
    ts = stamp.strftime("%Y-%m-%dT%H:%M:%SZ")
    sizes, size_gaps = collect_sizes(cfg, lc, uniq, f, ts)
    return {"schema": 1, "generatedAt": ts, "sources": sources, "gaps": gaps, "sizes": sizes, "sizeGaps": size_gaps,
            "candidates": [{"id": c.id, "kind": c.kind, "subject": c.subject, "model": c.model, "source": c.source.as_dict(),
                            "detail": c.detail, "url": c.url, **({"sizeGiB": c.size_gib} if c.size_gib is not None else {}),
                            **({"replacement": c.replacement} if c.replacement else {}),
                            "when": str(c.when or "")} for c in uniq]}


def read_previous(path) -> dict | None:
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def carry_pr_links(doc: dict, previous: dict | None) -> None:
    """The PR opener records the PR it opened for a candidate as `pr` in the report. The next watcher run writes the report again,
    so a link for a candidate that is still found is carried over (https only); one for a candidate that is gone is dropped."""
    links = {c.get("id"): c["pr"] for c in (previous or {}).get("candidates") or []
             if isinstance(c, dict) and isinstance(c.get("pr"), str) and c["pr"].startswith("https://")}
    for c in doc.get("candidates") or []:
        if c["id"] in links:
            c["pr"] = links[c["id"]]


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
    carry_pr_links(doc, read_previous(argv[2]))
    write_atomic(argv[2], doc)
    bad = [k for k, v in doc["sources"].items() if not v["ok"]]
    print(f"{len(doc['candidates'])} candidate(s); sources ok: {sorted(k for k, v in doc['sources'].items() if v['ok'])}"
          + (f"; FAILED: {bad}" if bad else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

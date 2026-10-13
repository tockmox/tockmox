# SPDX-License-Identifier: Apache-2.0
"""Model lifecycle (REQ-0048): the catalog, what the watcher found, gated promotion, residency.

Pure: no I/O, no clock reads except where a caller passes one in. The watcher (app/watcher.py)
does the fetching, in a separate process, and only when the operator turns it on; the UI
reads its report file. Everything the UI offers ends, as on /nodes, in a site-values change.

The rules this module exists to hold (REQ-0048 as revised by Jeff's rulings of 2026-10-07):

  1. A candidate never replaces what an alias points at, and no agent can reach it. Proposing a
     candidate adds it to the catalog at stage `candidate` and a `<alias>-next` route beside the live
     one, and `-next` routes render ONLY to the eval gateway (nodes.render_model_list). TM-0936 showed
     why: inside one LiteLLM, an access group fails open for any key with no model list, so the fence is
     the candidate not being in the production gateway at all.
  2. An alias moves only after `promotion.requiredPasses` passing comparisons of the candidate against
     the incumbent (default 3, per-class override), read from REQ-0045 comparative verdict records
     (AC-45.9, proposed in TM-0935). A fail resets the count; inconclusive neither counts nor resets.
     check_promotions() refuses values where an alias moved without that record; the UI refuses to start
     on them, and the same function is the CI gate (TM-0930).
  3. A new hosted model is a candidate too: it lands on the eval gateway with NO data-class tags. Its
     tags are chosen when it is promoted, through the same gate (the `open` default is withdrawn).

Two explicit approvals, each a merge of a change this module generates: admitting a candidate (it can
now be evaluated), and promoting it (it can now be used).
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import copy
import re
from dataclasses import dataclass, field

from .nodes import ALIAS_RE, ID_RE, Inventory, NodeError, Route, estimate_size_gib, fit, loading

STAGES = ("candidate", "promoted", "retired")
SOURCE_KINDS = ("huggingface", "ollama", "modelkit", "hosted")
TRACKS = ("revision", "quants", "successors", "deprecation")
CANDIDATE_KINDS = ("revision", "quant", "successor", "frontier", "deprecation", "digest")
RESIDENCY = ("pinned", "on-demand")
NEXT = "-next"


class LifecycleError(ValueError):
    pass


# ---------------------------------------------------------------- the catalog

@dataclass
class Source:
    kind: str                     # huggingface | ollama | modelkit | hosted
    ref: str                      # hf repo id | ollama name:tag | oci ref | provider/model id
    revision: str = ""            # hf commit sha | ollama manifest digest | oci digest | "" for hosted

    def as_dict(self):
        d = {"kind": self.kind, "ref": self.ref}
        if self.revision:
            d["revision"] = self.revision
        return d


@dataclass
class Entry:
    id: str
    model: str                    # the id routes use (the join to inferenceNodes.routes[].model)
    source: Source
    family: str = ""              # e.g. qwen3.8 ... what a successor is a successor OF
    base_model: str = ""          # e.g. Qwen/Qwen3.8-27B ... what a quant is a quant OF
    quant: str = ""
    size_gib: float | None = None
    stage: str = "promoted"
    track: tuple[str, ...] = ()
    promotion: dict = field(default_factory=dict)   # {alias|aliases, from, class, required, evidence:[{path,sha256,runId,date,verdict}]}
    adopted: str = ""             # date this model was taken into the catalog already in service (no eval on record)
    pending: dict = field(default_factory=dict)     # {revision, seen}: a newer build proposed for evaluation
    links: list = field(default_factory=list)       # [{title, url}] the operator adds: release notes, license ... https only

    def serves(self, alias: str) -> bool:
        p = self.promotion or {}
        return alias == p.get("alias") or alias in (p.get("aliases") or [])

    def as_dict(self):
        d = {"id": self.id, "model": self.model, "source": self.source.as_dict(), "stage": self.stage}
        for k, v in (("family", self.family), ("baseModel", self.base_model), ("quant", self.quant)):
            if v:
                d[k] = v
        if self.size_gib is not None:
            d["sizeGiB"] = self.size_gib
        if self.track:
            d["track"] = list(self.track)
        if self.promotion:
            d["promotion"] = self.promotion
        if self.adopted:
            d["adopted"] = self.adopted
        if self.pending:
            d["pending"] = self.pending
        if self.links:
            d["links"] = [dict(x) for x in self.links]
        return d


@dataclass
class ProfileClass:
    name: str
    alias: str
    priority: int = 5             # 1 is most important
    residency: str = "on-demand"


@dataclass
class Profile:
    id: str
    name: str
    classes: list[ProfileClass]


@dataclass
class Lifecycle:
    catalog: list[Entry] = field(default_factory=list)
    profiles: list[Profile] = field(default_factory=list)
    frontier_providers: dict = field(default_factory=dict)   # provider -> {"keyEnv": ...}
    active_profile: str = ""
    required_passes: int = 3                                 # Jeff, 2026-10-07: "3 is fine for now, but ... configurable"
    required_by_class: dict = field(default_factory=dict)    # class slug -> passes (REQ-0045 class 3 proposal: 1)
    eval_gateway_entries: list = field(default_factory=list)        # hosted entries a change adds (not serialised)
    production_gateway_entries: list = field(default_factory=list)  # hosted entries a promotion adds (not serialised)

    def required_for(self, klass: str) -> int:
        return int(self.required_by_class.get(klass, self.required_passes))

    def entry(self, eid: str) -> Entry | None:
        return next((e for e in self.catalog if e.id == eid), None)

    def by_model(self, model: str) -> Entry | None:
        return next((e for e in self.catalog if e.model == model), None)

    def profile(self, pid: str) -> Profile | None:
        return next((p for p in self.profiles if p.id == pid), None)


_HEX = re.compile(r"^(sha256:)?[0-9a-f]{7,64}$")


def _source(raw, where) -> Source:
    if not isinstance(raw, dict) or raw.get("kind") not in SOURCE_KINDS:
        raise LifecycleError(f"{where}: source.kind must be one of {SOURCE_KINDS}")
    ref = str(raw.get("ref", ""))
    if not ref or len(ref) > 200 or any(c.isspace() for c in ref):
        raise LifecycleError(f"{where}: source.ref {ref!r} is invalid")
    rev = str(raw.get("revision", "") or "")
    if rev and not _HEX.match(rev):
        raise LifecycleError(f"{where}: source.revision must be a commit sha or a digest, got {rev!r}")
    return Source(raw["kind"], ref, rev)


CLASS_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
SHA64 = re.compile(r"^[0-9a-f]{64}$")


_URL = re.compile(r"""^https://[A-Za-z0-9.-]+(:\d{1,5})?(/[^\s<>"'`]*)?$""")


def _links(raw, where) -> list:
    """Operator-supplied links (release notes, a license, a vendor post). https only, short, at most 10:
    they are rendered as links on the model's page and never fetched."""
    if raw in (None, []):
        return []
    if not isinstance(raw, list) or len(raw) > 10:
        raise LifecycleError(f"{where}: links must be a list of at most 10 {{title, url}}")
    out = []
    for x in raw:
        if not isinstance(x, dict) or not isinstance(x.get("title"), str) or not 0 < len(x["title"]) <= 60:
            raise LifecycleError(f"{where}: each link needs a title of 1 to 60 characters")
        url = str(x.get("url", ""))
        if len(url) > 500 or not _URL.match(url):
            raise LifecycleError(f"{where}: link {x['title']!r} must be an https:// URL")
        out.append({"title": x["title"], "url": url})
    return out


def _passes(v, where) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or not 1 <= v <= 20:
        raise LifecycleError(f"{where} must be a whole number from 1 to 20")
    return v


def parse(doc: dict | None) -> Lifecycle:
    doc = doc or {}
    lc = Lifecycle()
    ids, models = set(), set()
    for raw in doc.get("catalog") or []:
        eid = str(raw.get("id", ""))
        if not ID_RE.match(eid) or eid in ids:
            raise LifecycleError(f"catalog id {eid!r} invalid or duplicated")
        ids.add(eid)
        model = str(raw.get("model", ""))
        if not model or model in models or any(c.isspace() for c in model):
            raise LifecycleError(f"catalog {eid}: model {model!r} invalid or listed twice")
        models.add(model)
        stage = str(raw.get("stage", "promoted"))
        if stage not in STAGES:
            raise LifecycleError(f"catalog {eid}: stage must be one of {STAGES}")
        track = tuple(raw.get("track") or ())
        bad = [t for t in track if t not in TRACKS]
        if bad:
            raise LifecycleError(f"catalog {eid}: unknown track {bad}")
        size = raw.get("sizeGiB")
        if size is not None:
            try:
                size = float(size)
            except (TypeError, ValueError):
                raise LifecycleError(f"catalog {eid}: sizeGiB must be a number") from None
            if not 0 < size < 1e6:
                raise LifecycleError(f"catalog {eid}: sizeGiB must be positive")
        adopted = str(raw.get("adopted", "") or "")
        if adopted and not re.match(r"^\d{4}-\d{2}-\d{2}$", adopted):
            raise LifecycleError(f"catalog {eid}: adopted must be a date (YYYY-MM-DD)")
        pend = raw.get("pending") or {}
        if pend and not (isinstance(pend, dict) and _HEX.match(str(pend.get("revision", "")))):
            raise LifecycleError(f"catalog {eid}: pending.revision must be a commit sha or digest")
        lc.catalog.append(Entry(eid, model, _source(raw.get("source"), f"catalog {eid}"),
                                str(raw.get("family", "")), str(raw.get("baseModel", "")), str(raw.get("quant", "")),
                                size, stage, track, dict(raw.get("promotion") or {}), adopted, dict(pend),
                                _links(raw.get("links"), f"catalog {eid}")))
    pids = set()
    for raw in doc.get("profiles") or []:
        pid = str(raw.get("id", ""))
        if not ID_RE.match(pid) or pid in pids:
            raise LifecycleError(f"profile id {pid!r} invalid or duplicated")
        pids.add(pid)
        classes = []
        for name, c in (raw.get("classes") or {}).items():
            res = str(c.get("residency", "on-demand"))
            if res not in RESIDENCY:
                raise LifecycleError(f"profile {pid}.{name}: residency must be one of {RESIDENCY}")
            alias = str(c.get("alias", ""))
            if not ALIAS_RE.match(alias):
                raise LifecycleError(f"profile {pid}.{name}: alias {alias!r} invalid")
            pr = int(c.get("priority", 5))
            if not 1 <= pr <= 9:
                raise LifecycleError(f"profile {pid}.{name}: priority must be 1..9")
            classes.append(ProfileClass(str(name), alias, pr, res))
        lc.profiles.append(Profile(pid, str(raw.get("name", pid)), classes))
    fr = doc.get("frontier") or {}
    if "tags" in fr:
        # Jeff, 2026-10-07: new models, local or hosted, are unusable until explicitly approved. A default tag
        # would make a hosted model usable for that data class on arrival, so the key is refused, not ignored.
        raise LifecycleError("frontier.tags is withdrawn: a new hosted model lands untagged on the eval gateway, and its "
                             "data-class tags are chosen when it is promoted")
    lc.frontier_providers = dict(fr.get("providers") or {})
    pr = doc.get("promotion") or {}
    if not isinstance(pr, dict):
        raise LifecycleError("promotion must be a mapping")
    lc.required_passes = _passes(pr.get("requiredPasses", 3), "promotion.requiredPasses")
    by = pr.get("requiredPassesByClass") or {}
    if not isinstance(by, dict):
        raise LifecycleError("promotion.requiredPassesByClass must map a class to a number of passes")
    for k, v in by.items():
        if not CLASS_RE.match(str(k)):
            raise LifecycleError(f"promotion.requiredPassesByClass: {k!r} is not a class slug")
        lc.required_by_class[str(k)] = _passes(v, f"promotion.requiredPassesByClass.{k}")
    lc.active_profile = str(doc.get("activeProfile", "") or "")
    if lc.active_profile and lc.profile(lc.active_profile) is None:
        raise LifecycleError(f"activeProfile {lc.active_profile!r} is not a profile")
    return lc


def to_doc(lc: Lifecycle) -> dict:
    d = {"catalog": [e.as_dict() for e in lc.catalog]}
    if lc.profiles:
        d["profiles"] = [{"id": p.id, "name": p.name, "classes": {c.name: {"alias": c.alias, "priority": c.priority,
                          "residency": c.residency} for c in p.classes}} for p in lc.profiles]
    if lc.active_profile:
        d["activeProfile"] = lc.active_profile
    if lc.frontier_providers:
        d["frontier"] = {"providers": lc.frontier_providers}
    d["promotion"] = {"requiredPasses": lc.required_passes}
    if lc.required_by_class:
        d["promotion"]["requiredPassesByClass"] = dict(lc.required_by_class)
    return d


# ---------------------------------------------------------------- rule 2: the promotion gate

def evidence_problem(e: Entry) -> str:
    """Why e's promotion record does not prove the promotion, or "" when it does. The record must carry the
    class, the number of passes that was required, and that many passing comparisons with distinct run ids,
    each with the path and sha256 of its verdict file."""
    p = e.promotion or {}
    ev = p.get("evidence")
    if not isinstance(ev, list) or not ev:
        return "has no passing comparison on record"
    try:
        req = int(p.get("required", 0))
    except (TypeError, ValueError):
        req = 0
    if req < 1:
        return "does not record how many passing comparisons were required"
    runs = {str(x.get("runId")) for x in ev if isinstance(x, dict) and x.get("verdict") == "pass" and x.get("path")
            and x.get("runId") and SHA64.match(str(x.get("sha256", "")))}
    if len(runs) < req:
        return f"has {len(runs)} passing comparison(s) on record, {req} required"
    return ""


def check_promotions(lc: Lifecycle, inv: Inventory) -> list[str]:
    """Every problem with how live aliases point at catalog models. Empty means the gate passes.

    A live (non -next) alias may point at a catalogued model only if that model is `promoted` AND either
    (a) its promotion record names this alias and carries enough passing comparisons (evidence_problem), or
    (b) it carries `adopted: <date>`: it was already in service when it entered the catalog, said in a reviewable line.
    A promoted hosted model is held to the same record. What this function cannot do is open the verdict files:
    the record says WHICH bytes passed, and CI checks that the committed files hash to it (TM-0930).
    (Review finding 2026-10-07: a stage flipped by hand, or a promotion for another alias, used to pass.)"""
    problems = []
    for r in inv.routes:
        e = lc.by_model(r.model)
        if e is None or r.alias.endswith(NEXT):
            continue
        if e.stage == "candidate":
            problems.append(f"route {r.alias} points at {r.model}, which is still a candidate: "
                            f"promote it with passing comparisons first, or route it as {r.alias}{NEXT}")
            continue
        if e.stage == "retired":
            problems.append(f"route {r.alias} points at {r.model}, which is retired")
            continue
        if e.serves(r.alias):
            why = evidence_problem(e)
            if why:
                problems.append(f"route {r.alias}: the promotion of {r.model} {why}")
        elif not e.adopted:
            problems.append(f"route {r.alias} points at {r.model}, which has no promotion for {r.alias} and no adopted date")
    for e in lc.catalog:
        if e.source.kind == "hosted" and e.stage == "promoted" and not e.adopted:
            why = evidence_problem(e) if e.promotion else "has no promotion record and no adopted date"
            if why:
                problems.append(f"hosted model {e.model} is promoted but {why}")
    return problems


def promotion_notes(lc: Lifecycle) -> list[str]:
    """Promotions made under a lower bar than today's. Not a gate failure: raising requiredPasses must not
    stop the UI from starting on models that were promoted properly under the old setting."""
    out = []
    for e in lc.catalog:
        p = e.promotion or {}
        if e.stage == "promoted" and p.get("class") and isinstance(p.get("required"), int) \
                and p["required"] < lc.required_for(str(p["class"])):
            out.append(f"{e.model} was promoted with {p['required']} passing comparison(s); class {p['class']} now requires "
                       f"{lc.required_for(str(p['class']))}")
    return out


# ---------------------------------------------------------------- comparative verdicts (REQ-0045 AC-45.9, proposed)

VERDICT_SCHEMA = "comparative-verdict/1"
GRADERS = ("rule", "judge", "jeff")
VERDICTS = ("pass", "fail", "inconclusive")


@dataclass
class Verdict:
    run_id: str
    date: str
    klass: str
    alias: str
    incumbent: dict               # {model, revision}; {} when there is no incumbent
    candidate: dict               # {model, revision}
    eval_set: tuple               # (id, version)
    grader: str
    verdict: str
    sha256: str
    path: str = ""                # where the file sits in the site repo (the promotion records it)


def parse_verdict(text: str, path: str = "") -> Verdict:
    """One comparison run, as REQ-0045 (proposed AC-45.9) has the eval runner write it."""
    if len(text) > 256 * 1024:
        raise LifecycleError("verdict record larger than 256 KB")
    try:
        d = json.loads(text)
    except ValueError:
        raise LifecycleError("verdict record is not JSON") from None
    if not isinstance(d, dict) or d.get("schema") != VERDICT_SCHEMA:
        raise LifecycleError(f'verdict record needs "schema": "{VERDICT_SCHEMA}"')
    for k in ("run_id", "date", "class", "alias", "grader", "verdict", "criterion"):
        if not isinstance(d.get(k), str) or not d[k]:
            raise LifecycleError(f"verdict record is missing {k!r}")
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$", d["run_id"]):
        raise LifecycleError("verdict run_id must be a short identifier")
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", d["date"]) or not CLASS_RE.match(d["class"]):
        raise LifecycleError("verdict date must be YYYY-MM-DD and class a slug")
    alias = d["alias"][: -len(NEXT)] if d["alias"].endswith(NEXT) else d["alias"]
    if not ALIAS_RE.match(alias):
        raise LifecycleError(f"verdict alias {d['alias']!r} is not an alias")
    if d["grader"] not in GRADERS or d["verdict"] not in VERDICTS:
        raise LifecycleError(f"verdict grader must be one of {GRADERS} and verdict one of {VERDICTS}")

    def side(k, required):
        v = d.get(k)
        if v is None and not required:
            return {}
        if not isinstance(v, dict) or not isinstance(v.get("model"), str) or not v["model"]:
            raise LifecycleError(f"verdict {k} must be {{model, revision}}")
        rev = str(v.get("revision", "") or "")
        if rev and not _HEX.match(rev):
            raise LifecycleError(f"verdict {k}.revision must be a commit sha or a digest")
        return {"model": v["model"], "revision": rev}
    es = d.get("eval_set")
    if not isinstance(es, dict) or not es.get("id") or not es.get("version"):
        raise LifecycleError("verdict eval_set must be {id, version}")
    return Verdict(d["run_id"], d["date"], d["class"], alias, side("incumbent", False), side("candidate", True),
                   (str(es["id"]), str(es["version"])), d["grader"], d["verdict"],
                   hashlib.sha256(text.encode("utf-8")).hexdigest(), path)


def count_passes(verdicts, alias: str, model: str, revision: str = "", incumbent: str | None = None):
    """The passing comparisons that count toward moving `alias` to `model`, oldest first, and notes on what
    did not count. Only `pass` counts; a `fail` resets the count; `inconclusive` neither counts nor resets;
    a run id counts once; only passes on the newest eval-set version count; a record for another build
    (revision) or against another incumbent does not count."""
    notes, counted, seen = [], [], set()
    rel = sorted((v for v in verdicts if v.alias == alias and v.candidate.get("model") == model),
                 key=lambda v: (v.date, v.run_id))
    for v in rel:
        if revision and v.candidate.get("revision") and \
                v.candidate["revision"].replace("sha256:", "") != revision.replace("sha256:", ""):
            notes.append(f"{v.run_id} ({v.date}) tested build {v.candidate['revision'][:19]}, not the pinned one: not counted")
            continue
        if incumbent is not None and (v.incumbent.get("model") or "") != incumbent:
            notes.append(f"{v.run_id} ({v.date}) compared against {v.incumbent.get('model') or 'nothing'}, "
                         f"not the current {incumbent or 'nothing'}: not counted")
            continue
        if v.verdict == "fail":
            if counted:
                notes.append(f"{v.run_id} ({v.date}) failed: the {len(counted)} pass(es) before it no longer count")
            else:
                notes.append(f"{v.run_id} ({v.date}) failed")
            counted, seen = [], set()
        elif v.verdict == "inconclusive":
            notes.append(f"{v.run_id} ({v.date}) was inconclusive: neither counted nor reset")
        elif v.run_id in seen:
            notes.append(f"{v.run_id} appears twice: counted once")
        else:
            counted.append(v)
            seen.add(v.run_id)
    if counted:
        newest = counted[-1].eval_set
        old = [v for v in counted if v.eval_set != newest]
        if old:
            notes.append(f"{len(old)} earlier pass(es) used another version of eval set {newest[0]}: not counted")
            counted = [v for v in counted if v.eval_set == newest]
        classes = {v.klass for v in counted}
        if len(classes) > 1:
            notes.append(f"passes span classes {sorted(classes)}: only class {counted[-1].klass} counts")
            counted = [v for v in counted if v.klass == counted[-1].klass]
    return counted, notes


# ---------------------------------------------------------------- the watcher's report

@dataclass
class Candidate:
    id: str
    kind: str                     # revision | quant | successor | frontier | deprecation | digest
    subject: str                  # catalog entry id, or provider for frontier
    model: str                    # the new model id (as a route would call it)
    source: Source
    detail: str
    url: str = ""
    size_gib: float | None = None
    when: str = ""


@dataclass
class Report:
    generated_at: str
    sources: dict                 # name -> {"ok": bool, "reason": str}
    candidates: list[Candidate]
    gaps: list = field(default_factory=list)   # catalog entries the watcher could not check, and why


def parse_report(d: dict) -> Report:
    if not isinstance(d, dict) or d.get("schema") != 1:
        raise LifecycleError("watcher report needs \"schema\": 1")
    cands = []
    for c in (d.get("candidates") or [])[:1000]:
        if c.get("kind") not in CANDIDATE_KINDS:
            continue
        cands.append(Candidate(str(c["id"])[:200], c["kind"], str(c.get("subject", ""))[:80], str(c.get("model", ""))[:200],
                               _source(c.get("source"), "candidate"), str(c.get("detail", ""))[:400],
                               str(c.get("url", ""))[:300] if str(c.get("url", "")).startswith("https://") else "",
                               float(c["sizeGiB"]) if isinstance(c.get("sizeGiB"), (int, float)) else None,
                               str(c.get("when", ""))[:40]))
    gaps = [str(g)[:200] for g in (d.get("gaps") or [])[:200]]
    return Report(str(d.get("generatedAt", "")), dict(d.get("sources") or {}), cands, gaps)


# ---------------------------------------------------------------- detectors (pure; the watcher feeds them)

_FAMILY_RE = re.compile(r"(?i)^(?P<name>[a-z]+)[-_ ]?(?P<ver>\d+(?:\.\d+)*)")


def family_of(model_id: str) -> tuple[str, tuple[int, ...]] | None:
    """('qwen', (3, 8)) from 'Qwen/Qwen3.8-27B' or 'mlx-community/Qwen3.8-27B-4bit'."""
    m = _FAMILY_RE.match(model_id.split("/")[-1])
    if not m:
        return None
    return m.group("name").lower(), tuple(int(x) for x in m.group("ver").split("."))


def _param_tag(model_id: str) -> str:
    m = re.search(r"(?i)(\d+(?:\.\d+)?b)(?:-a\d+(?:\.\d+)?b)?", model_id.split("/")[-1])
    return m.group(0).lower() if m else ""


def detect_hf(entry: Entry, repo_info: dict | None, siblings: list[dict], newer_bases: list[dict],
              quant_authors=()) -> list[Candidate]:
    """repo_info: GET /api/models/<repo> for the entry's own repo (sha, lastModified).
    siblings: GET /api/models?filter=base_model:<base> (other quants of the same base).
    newer_bases: GET /api/models?author=<org>&sort=createdAt (candidate successors)."""
    out = []
    ref = entry.source.ref
    if "revision" in entry.track and repo_info and repo_info.get("sha") and entry.source.revision \
            and not str(repo_info["sha"]).startswith(entry.source.revision.replace("sha256:", "")):
        out.append(Candidate(f"revision:{ref}@{repo_info['sha'][:12]}", "revision", entry.id, entry.model,
                             Source("huggingface", ref, repo_info["sha"]),
                             f"{ref} has a new commit ({entry.source.revision[:12]} -> {repo_info['sha'][:12]})",
                             f"https://huggingface.co/{ref}/commits/main", entry.size_gib, str(repo_info.get("lastModified", ""))))
    if "quants" in entry.track and entry.base_model:
        mine = entry.quant.lower()
        for s in siblings[:200]:
            sid = str(s.get("id", ""))
            if not sid or sid == ref or sid.split("/")[0] not in quant_authors:
                continue
            if mine and mine in sid.lower():
                continue          # same quant from another publisher: not new information
            out.append(Candidate(f"quant:{sid}", "quant", entry.id, sid, Source("huggingface", sid, str(s.get("sha", "") or "")),
                                 f"another quantisation of {entry.base_model}: {sid}",
                                 f"https://huggingface.co/{sid}", estimate_size_gib(sid), str(s.get("lastModified", ""))))
    if "successors" in entry.track:
        fam = family_of(entry.base_model or entry.model)
        size = _param_tag(entry.base_model or entry.model)
        if fam:
            for b in newer_bases[:200]:
                bid = str(b.get("id", ""))
                bf = family_of(bid)
                if not bf or bf[0] != fam[0] or bf[1] <= fam[1]:
                    continue
                if size and _param_tag(bid) != size:
                    continue      # another size, or no size in the name: a different placement question, not an upgrade
                                  # (lab finding: "Qwen3.8-Flash-Next" was offered as the successor of Qwen2.5-7B)
                out.append(Candidate(f"successor:{bid}", "successor", entry.id, bid, Source("huggingface", bid, ""),
                                     f"{bid} is a newer {fam[0]} ({'.'.join(map(str, bf[1]))} after {'.'.join(map(str, fam[1]))})",
                                     f"https://huggingface.co/{bid}", estimate_size_gib(bid), str(b.get("createdAt", ""))))
    return out


def detect_ollama(entry: Entry, remote_digest: str | None, pushed: str = "") -> list[Candidate]:
    if not remote_digest or not entry.source.revision or "revision" not in entry.track:
        return []
    if remote_digest.replace("sha256:", "") == entry.source.revision.replace("sha256:", ""):
        return []
    return [Candidate(f"digest:{entry.source.ref}@{remote_digest[-12:]}", "digest", entry.id, entry.model,
                      Source("ollama", entry.source.ref, remote_digest),
                      f"the registry's {entry.source.ref} is a new build ({entry.source.revision[-12:]} -> {remote_digest[-12:]})",
                      f"https://ollama.com/library/{entry.source.ref.split(':')[0]}", entry.size_gib, pushed)]


def detect_frontier(provider: str, listed: list[dict], known: set[str], allow: list[str] | None = None) -> list[Candidate]:
    """listed: [{id, created?, shutdown?}] normalised by the watcher. known: model ids the gateway
    already routes for this provider. allow: optional glob filter (e.g. ["claude-*"])."""
    out = []
    for m in listed[:500]:
        mid = str(m.get("id", ""))
        if not mid or mid in known:
            continue
        if allow and not any(fnmatch.fnmatch(mid, p) for p in allow):
            continue
        out.append(Candidate(f"frontier:{provider}/{mid}", "frontier", provider, f"{provider}/{mid}",
                             Source("hosted", f"{provider}/{mid}", ""), f"{provider} lists {mid}, which the gateway does not route",
                             "", None, str(m.get("created", ""))))
    for m in listed[:500]:
        mid = str(m.get("id", ""))
        if mid in known and m.get("shutdown"):
            out.append(Candidate(f"deprecation:{provider}/{mid}", "deprecation", provider, f"{provider}/{mid}",
                                 Source("hosted", f"{provider}/{mid}", ""), f"{provider} retires {mid} on {m['shutdown']}",
                                 "", None, str(m["shutdown"])))
    return out


# ---------------------------------------------------------------- turning a candidate into a change (rule 1, rule 3)

def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40].strip("-") or "model"


def propose(cand: Candidate, lc: Lifecycle, inv: Inventory, node: str = "", endpoint: str = "", taken=()) -> tuple[Lifecycle, Inventory, list[str]]:
    """The ADDITIONS a candidate becomes: (lifecycle additions, inventory additions, notes). Merge them."""
    notes = []
    if cand.kind == "deprecation":
        raise LifecycleError("a deprecation is a notice, not something to add: plan the replacement route instead")
    if cand.kind == "frontier":
        return _propose_frontier(cand, lc, inv, taken)
    base = lc.entry(cand.subject)
    if base is None:
        raise LifecycleError(f"candidate {cand.id} names catalog entry {cand.subject!r}, which is not in the catalog")
    eid = _slug(cand.model.split("/")[-1])
    taken = {e.id for e in lc.catalog}
    i = 2
    while eid in taken:
        eid, i = f"{_slug(cand.model.split('/')[-1])[:36]}-{i}", i + 1
    same_bytes = cand.kind in ("revision", "digest")
    if same_bytes:
        # Same model id, new bytes: the entry stays as it is (its live aliases keep passing the gate) and the
        # newer build is recorded as pending. Review finding: staging the whole entry as a candidate made the
        # gate refuse every revision proposal for a model with a live route, which is the main case.
        pend = Entry(base.id, base.model, base.source, base.family, base.base_model, base.quant, base.size_gib,
                     base.stage, base.track, dict(base.promotion), base.adopted,
                     {"revision": cand.source.revision, "seen": cand.when or ""})
        return Lifecycle([pend]), Inventory(), [
            f"records {cand.source.revision[:19]} as the pending build of {base.model}; the live pin is unchanged",
            "to evaluate it, pull that build on a node that is not serving the live alias (or accept a short window), "
            "run the eval, then move source.revision to the pending value in a reviewed change"]
    entry = Entry(eid if not same_bytes else base.id, cand.model, cand.source, base.family if same_bytes else "",
                  base.base_model if cand.kind in ("revision", "digest", "quant") else "", "" if not same_bytes else base.quant,
                  cand.size_gib if cand.size_gib is not None else base.size_gib if same_bytes else None,
                  "candidate", base.track, {})
    if same_bytes:
        # A new revision of the same repo or tag is the same model id on the wire: the -next route
        # cannot run beside it on one engine. The change pins the new revision as a candidate; the
        # node is updated by the operator and the eval runs against it before the stage moves.
        notes.append("same model id, new bytes: pull it on a node that is not serving the live alias, or accept a "
                     "short window where the live alias runs the candidate; the eval decides whether it stays")
    live = [r for r in inv.routes if r.model == base.model and not r.alias.endswith(NEXT)]
    routes = []
    if not same_bytes:
        taken = {x.alias: x for x in inv.routes}
        for r in live or []:
            busy = taken.get(r.alias + NEXT)
            if busy is not None and busy.model != cand.model:
                # one candidate per alias at a time: the slot is already running a comparison
                # (the reference homelab names its own comparison routes exactly this way)
                notes.append(f"{r.alias}{NEXT} already serves {busy.model}: promote or remove that comparison first; "
                             f"no {r.alias}{NEXT} route was added")
                continue
            n = node or r.node
            ep = endpoint or r.endpoint
            # deep copies: a shallow dict shared the incumbent's tags LIST, which PyYAML then wrote as an anchor
            # (&id001 / *id001) in the machine-owned values file (site PR #114, TM-0939)
            routes.append(Route(r.alias + NEXT, n, ep, cand.model, r.kind, r.provider, copy.deepcopy(r.params),
                                copy.deepcopy(r.model_info), entry.size_gib))
        if not live:
            notes.append(f"no live route uses {base.model}; place the candidate from its node page")
        elif not routes:
            raise LifecycleError("every alias this would sit beside already has a -next comparison running: " + "; ".join(notes))
        notes.append("pull the model onto the node before committing, or the -next route will fail until you do")
        if routes:
            notes.append("the -next route goes to the EVAL gateway only; the production gateway never sees it, so no agent "
                         "can call the candidate until a promotion moves the alias")
    add_lc = Lifecycle([entry])
    add_inv = Inventory([inv.node(r.node) for r in routes if inv.node(r.node)], routes)
    return add_lc, add_inv, notes


def _propose_frontier(cand, lc, inv, taken=()):
    if "/" not in cand.model:
        raise LifecycleError(f"{cand.model!r} is not provider/model")
    provider, mid = cand.model.split("/", 1)
    alias = mid
    if not ALIAS_RE.match(alias):
        raise LifecycleError(f"{mid!r} cannot be a gateway alias")
    if alias in set(taken) | inv.aliases():
        # review finding: a hosted model named like a local route would share its model_name, and the gateway
        # load-balances one name across every deployment that carries it ... private traffic to a hosted API
        raise LifecycleError(f"the gateway already has a route called {alias}; adding a hosted model under the same name "
                             "would spread that route's traffic to the provider")
    entry = Entry(_slug(f"{provider}-{mid}"), cand.model, cand.source, stage="candidate", track=("deprecation",))
    keyenv = (lc.frontier_providers.get(provider) or {}).get("keyEnv", f"{provider.upper()}_API_KEY")
    notes = ["admitted to the EVAL gateway only, with no data-class tags: no agent can call it (the production "
             "gateway does not have it, which TM-0936 showed is the only fence that holds for every key)",
             f"start an evaluation against the alias it should compete for; after enough passing comparisons, promoting "
             f"it is a separate change, and that is where you choose its data-class tags"]
    eval_entry = {"model_name": alias, "litellm_params": {"model": cand.model, "api_key": f"os.environ/{keyenv}"},
                  "model_info": {"endpoint_tier": "external", "tockmox_catalog": entry.id}}
    add = Lifecycle([entry])
    add.eval_gateway_entries = [eval_entry]
    return add, Inventory(), notes


def hosted_candidate_entries(lc: Lifecycle) -> list[dict]:
    """The eval gateway's entries for hosted catalog entries at stage candidate (no data-class tags). The
    chart derives the same list (tockmox-ai.hostedCandidates); tests/golden in tockmox/tockmox pins it."""
    out = []
    for e in lc.catalog:
        if e.stage != "candidate" or e.source.kind != "hosted" or "/" not in e.source.ref:
            continue
        provider, mid = e.source.ref.split("/", 1)
        keyenv = (lc.frontier_providers.get(provider) or {}).get("keyEnv", f"{provider.upper()}_API_KEY")
        out.append({"model_name": mid, "litellm_params": {"model": e.source.ref, "api_key": f"os.environ/{keyenv}"},
                    "model_info": {"endpoint_tier": "external", "tockmox_catalog": e.id}})
    return out


TAG_RE = re.compile(r"^[A-Za-z0-9:_.!-]{1,40}$")


def _passed(alias, model, verdicts, lc, revision="", incumbent=None):
    counted, notes = count_passes(verdicts, alias, model, revision, incumbent)
    if not counted:
        raise LifecycleError(f"there is no passing comparison of {model} for {alias} on record" +
                             (f" ({'; '.join(notes)})" if notes else ""))
    klass = counted[-1].klass
    req = lc.required_for(klass)
    if len(counted) < req:
        raise LifecycleError(f"{len(counted)} of {req} passing comparisons for class {klass}: not yet" +
                             (f" ({'; '.join(notes)})" if notes else ""))
    return counted, klass, req, notes


def _record(alias, old, klass, req, counted, **extra):
    return {"alias": alias, "from": old, "class": klass, "required": req, **extra,
            "evidence": [{"path": v.path or f"evals/verdicts/{v.run_id}.json", "sha256": v.sha256, "runId": v.run_id,
                          "date": v.date, "verdict": "pass", "grader": v.grader} for v in counted]}


def promote(alias_next: str, verdicts, lc: Lifecycle, inv: Inventory) -> tuple[Lifecycle, Inventory, list[str]]:
    """Repoint <alias> at what <alias>-next serves, with the counted comparisons on record. Refuses on any shortfall.
    Returns the WHOLE new lifecycle and inventory (a promotion removes a route, which a merge cannot)."""
    if not alias_next.endswith(NEXT):
        raise LifecycleError("promote a -next route; the live alias is what moves")
    nxt = next((r for r in inv.routes if r.alias == alias_next), None)
    if nxt is None:
        raise LifecycleError(f"no route {alias_next}")
    alias = alias_next[: -len(NEXT)]
    live = next((r for r in inv.routes if r.alias == alias), None)
    e = lc.by_model(nxt.model)
    if e is None:
        raise LifecycleError(f"{nxt.model} is not in the catalog; propose it first")
    if e.stage == "retired":
        raise LifecycleError(f"{nxt.model} is retired")
    old = live.model if live else ""
    counted, klass, req, cnotes = _passed(alias, nxt.model, verdicts, lc, e.source.revision, old)
    promoted = Entry(e.id, e.model, e.source, e.family, e.base_model, e.quant, e.size_gib, "promoted", e.track,
                     _record(alias, old, klass, req, counted))
    new_live = Route(alias, nxt.node, nxt.endpoint, nxt.model, nxt.kind, nxt.provider,
                     dict(live.params if live else nxt.params), dict(live.model_info if live else nxt.model_info), nxt.size_gib)
    add_lc = Lifecycle([promoted])
    notes = list(cnotes)
    still = sorted(r.alias for r in inv.routes if r.model == old and r.alias not in (alias, alias_next) and not r.alias.endswith(NEXT))
    if old and lc.by_model(old) and not still:
        o = lc.by_model(old)
        add_lc.catalog.append(Entry(o.id, o.model, o.source, o.family, o.base_model, o.quant, o.size_gib, "retired", o.track,
                                    o.promotion, o.adopted))
        notes.append(f"{old} is marked retired; remove its files from the node")
    elif still:
        # review finding: retiring a model other live aliases still use made the gate refuse the promotion
        notes.append(f"{old} stays in service: {', '.join(still)} still route to it")
    notes.append(f"commit the {len(counted)} verdict file(s) this cites in the same change "
                 f"({', '.join(x['path'] for x in promoted.promotion['evidence'])}); their sha256 is recorded")
    from .nodes import inventory_to_doc, parse_inventory
    new_inv = parse_inventory(inventory_to_doc(inv))
    new_inv.routes = [x for x in new_inv.routes if x.alias not in (alias, alias_next)] + [new_live]
    new_inv = parse_inventory(inventory_to_doc(new_inv))
    return merge(lc, add_lc), new_inv, notes + [
        f"{alias} serves {nxt.model} on the production gateway with this change; {alias_next} leaves the eval gateway"]


def promote_hosted(entry_id: str, alias: str, tags, verdicts, lc: Lifecycle, gateway_names=()) -> tuple[Lifecycle, list[str]]:
    """A hosted candidate onto the production gateway as `alias`, with the data-class tags the operator chose
    now, after enough passing comparisons against what `alias` serves today (or against nothing, if new)."""
    e = lc.entry(entry_id)
    if e is None or e.source.kind != "hosted":
        raise LifecycleError(f"{entry_id!r} is not a hosted model in the catalog")
    if e.stage != "candidate":
        raise LifecycleError(f"{e.model} is {e.stage}, not a candidate")
    if not ALIAS_RE.match(alias or "") or alias.endswith(NEXT):
        raise LifecycleError(f"{alias!r} is not an alias the production gateway can serve")
    tags = [t for t in (tags or []) if t]
    if not tags or not all(TAG_RE.match(t) for t in tags):
        raise LifecycleError("choose at least one data-class tag: they are what the gateway's policy routes on")
    counted, klass, req, cnotes = _passed(alias, e.model, verdicts, lc, "", None)
    provider = e.model.split("/", 1)[0]
    keyenv = (lc.frontier_providers.get(provider) or {}).get("keyEnv", f"{provider.upper()}_API_KEY")
    promoted = Entry(e.id, e.model, e.source, e.family, e.base_model, e.quant, e.size_gib, "promoted", e.track,
                     _record(alias, "", klass, req, counted, tags=list(tags)))
    out = merge(lc, Lifecycle([promoted]))
    out.production_gateway_entries = [{"model_name": alias, "litellm_params": {"model": e.model, "api_key": f"os.environ/{keyenv}",
                                       "tags": list(tags)}, "model_info": {"endpoint_tier": "external", "tockmox_catalog": e.id}}]
    notes = list(cnotes) + [f"tagged {', '.join(tags)}: the gateway's policy decides which data may reach it",
                            f"remove {e.model.split('/', 1)[1]} from the eval gateway once this is live"]
    if alias in set(gateway_names):
        notes.append(f"the production gateway already has {alias}: replace that entry, or the gateway will spread {alias}'s "
                     "traffic across both")
    return out, notes


def eval_request(alias: str, klass: str, runs: int, candidate: dict, incumbent: dict, who: str, when: str) -> dict:
    """What the Models page asks the REQ-0045 runner to do. The UI writes nothing: this is a file to commit
    (or a comment on the candidate's admit PR) that the runner picks up."""
    if not ALIAS_RE.match(alias or "") or alias.endswith(NEXT):
        raise LifecycleError("an evaluation decides a live alias, not a -next one")
    if not CLASS_RE.match(klass or ""):
        raise LifecycleError("class must be a slug (the REQ-0045 workload class)")
    if isinstance(runs, bool) or not isinstance(runs, int) or not 1 <= runs <= 20:
        raise LifecycleError("runs must be a whole number from 1 to 20")
    return {"schema": "eval-request/1", "alias": alias, "class": klass, "runs": runs,
            "candidate": {k: v for k, v in candidate.items() if v}, "incumbent": {k: v for k, v in (incumbent or {}).items() if v},
            "gateway": "eval", "requestedBy": who, "requestedAt": when}


MANAGED_LC_KEYS = ("catalog", "profiles", "activeProfile", "frontier", "promotion")


def change_doc(lc_raw: dict | None, nodes_raw: dict | None, new_lc: "Lifecycle", new_inv) -> dict:
    """The two values blocks a change replaces, carrying every other key the operator set (reportFile, watch,
    verdictsDir ...; probe, gateway ...), plus the gateway's rolling annotation (nodes.roll_block). The ONE place
    the UI and the PR opener build a change from."""
    from .nodes import inventory_to_doc, roll_block
    lc_block = {k: v for k, v in (lc_raw or {}).items() if k not in MANAGED_LC_KEYS}
    lc_block.update(to_doc(new_lc))
    in_block = {k: v for k, v in (nodes_raw or {}).items() if k not in ("nodes", "routes")}
    in_block.update(inventory_to_doc(new_inv))
    return {"modelLifecycle": lc_block, "inferenceNodes": in_block, "litellm": roll_block(new_inv)}


def merge(base: Lifecycle, add: Lifecycle) -> Lifecycle:
    out = parse(to_doc(base))
    for e in add.catalog:
        out.catalog = [x for x in out.catalog if x.id != e.id and x.model != e.model] + [e]
    res = parse(to_doc(out))
    res.eval_gateway_entries = list(base.eval_gateway_entries) + list(add.eval_gateway_entries)
    res.production_gateway_entries = list(base.production_gateway_entries) + list(add.production_gateway_entries)
    return res


# ---------------------------------------------------------------- where a model comes from (TM-0938)

HF_REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")
OLLAMA_NAME = re.compile(r"^([a-z0-9][a-z0-9._-]{0,63}/)?[a-z0-9][a-z0-9._-]{0,63}$")
SLUGPART = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
# Provider pages move (both of these redirected from their old addresses in 2026), so a site can override them
# with modelLifecycle.providerPages. {model} is replaced by the provider's model id where the page is per model.
PROVIDER_PAGES = {
    "anthropic": "https://platform.claude.com/docs/en/models/overview",
    "openai": "https://developers.openai.com/api/docs/models/{model}",
    "openrouter": "https://openrouter.ai/{model}",
}


# A ModelKit (KitOps) lives in an OCI registry the SITE runs, so there is no default page: a site names each
# registry host it uses in modelLifecycle.modelkitRegistries, mapped to an https page template.
# {repository} is the path after the host, {reference} the tag or the sha256 digest.
REGISTRY_HOST = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:\d{1,5})?$")
OCI_REPO_PART = re.compile(r"^[a-z0-9]+([._-][a-z0-9]+)*$")
OCI_TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
OCI_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def _modelkit_link(ref: str, registries: dict) -> str | None:
    """The registry page for host/repository[:tag|@digest], or None when the host is not one the site named or
    any part does not look like an OCI reference. Never guessed, never fetched."""
    if "/" not in ref:
        return None
    host, rest = ref.split("/", 1)
    tpl = (registries or {}).get(host)
    if not tpl or not REGISTRY_HOST.match(host):
        return None
    if "@" in rest:
        repo, reference = rest.split("@", 1)
        if not OCI_DIGEST.match(reference):
            return None
    elif ":" in rest.rsplit("/", 1)[-1]:
        repo, reference = rest.rsplit(":", 1)
        if not OCI_TAG.match(reference):
            return None
    else:
        repo, reference = rest, "latest"
    if not repo or not all(OCI_REPO_PART.match(p) for p in repo.split("/")):
        return None
    return tpl.replace("{repository}", repo).replace("{reference}", reference)


def source_links(e: Entry, provider_pages: dict | None = None, modelkit_registries: dict | None = None) -> list[tuple[str, str]]:
    """(label, url) for where e's bytes or API come from, built from the catalog's own fields and never
    fetched. A ref that does not look like what its kind expects gets no link rather than a guessed one."""
    pages = {**PROVIDER_PAGES, **(provider_pages or {})}
    out, ref, rev = [], e.source.ref, e.source.revision
    if e.source.kind == "huggingface" and HF_REPO.match(ref):
        out.append(("Model card", f"https://huggingface.co/{ref}"))
        if rev and re.match(r"^[0-9a-f]{7,40}$", rev):
            out.append((f"Files at the pinned build ({rev[:12]})", f"https://huggingface.co/{ref}/tree/{rev}"))
        out.append(("Commit history", f"https://huggingface.co/{ref}/commits/main"))
    elif e.source.kind == "ollama":
        name = ref.split(":", 1)[0]
        if OLLAMA_NAME.match(name):
            base = f"https://ollama.com/{name}" if "/" in name else f"https://ollama.com/library/{name}"
            out += [("Library page", base), ("Tags and builds", base + "/tags")]
    elif e.source.kind == "modelkit":
        url = _modelkit_link(ref, modelkit_registries)
        if url:
            out.append(("Registry page", url))
    elif e.source.kind == "hosted" and "/" in ref:
        provider, mid = ref.split("/", 1)
        tpl = pages.get(provider)
        if tpl and all(SLUGPART.match(p) for p in mid.split("/")):
            out.append((f"{provider} model page", tpl.replace("{model}", mid)))
    if e.base_model and HF_REPO.match(e.base_model) and e.base_model != ref:
        out.append((f"Base model ({e.base_model})", f"https://huggingface.co/{e.base_model}"))
    return [(label, url) for label, url in out if _URL.match(url)]


# ---------------------------------------------------------------- residency (workload profiles)

@dataclass
class Placement:
    alias: str
    model: str
    endpoint: str
    engine: str
    size_gib: float | None
    priority: int
    want: str                     # what the profile asked for
    got: str                      # pinned | on-demand | unprofiled
    why: str = ""


@dataclass
class Plan:
    node: str
    usable_gib: float | None
    pinned_gib: float
    largest_on_demand_gib: float
    placements: list[Placement]
    warnings: list[str]


def plan_residency(node, routes: list[Route], profile: Profile | None) -> Plan:
    """Pinned = held in memory all the time; on-demand = loaded on first request, unloaded on TTL or pressure.

    Planned per MODEL on an endpoint (two aliases on one model are one copy; the strongest wish among them
    wins). Engines that cannot unload (vLLM, SGLang, NIM, TGI, or a plain server not behind llama-swap) hold
    their model whatever the profile says: they are counted as resident. Pinned wishes are granted in
    priority order while the pinned set plus the largest on-demand model fits; the largest on-demand model
    is recomputed after every demotion (review finding: it was computed once, before demotions)."""
    pri = {c.alias: c for c in (profile.classes if profile else [])}
    usable = fit(node, [], 0.0).usable_gib
    swappable = set(ENGINE_CMD) | {"ollama", "lm-studio", "exo"}
    groups: dict = {}
    for r in sorted(routes, key=lambda r: (pri[r.alias].priority if r.alias in pri else 9, r.alias)):
        groups.setdefault((r.endpoint, r.model), []).append(r)
    rows, warnings, models = [], [], []
    for (eid, model), rs in groups.items():
        ep = node.endpoint(eid)
        eng = ep.engine if ep else "?"
        want = "pinned" if any(pri.get(r.alias) and pri[r.alias].residency == "pinned" for r in rs) else \
            ("on-demand" if any(r.alias in pri for r in rs) else "unprofiled")
        best = min((pri[r.alias].priority for r in rs if r.alias in pri), default=9)
        size = next((r.size_gib for r in rs if r.size_gib is not None), None)
        m = {"rs": rs, "eng": eng, "want": want, "prio": best, "size": size,
             "got": "resident" if eng not in swappable else ("on-demand" if want != "pinned" else "?"), "why": ""}
        if eng not in swappable:
            m["why"] = f"{eng} holds its model while it runs"
        models.append(m)
    resident = sum(m["size"] or 0 for m in models if m["got"] == "resident")

    def largest_od():
        return max([m["size"] or 0 for m in models if m["got"] in ("on-demand", "?") and m["want"] != "pinned"] or [0.0])

    pinned = resident
    for m in sorted([m for m in models if m["got"] == "?"], key=lambda m: m["prio"]):
        need = m["size"]
        if need is None:
            m["got"], m["why"] = "pinned", "size unknown: not counted, so the plan may be optimistic"
        elif usable is None:
            m["got"], m["why"] = "pinned", "no memory figure for this node: not checked"
            pinned += need
        elif pinned + need + largest_od() <= usable:
            m["got"] = "pinned"
            pinned += need
        else:
            m["got"] = "on-demand"
            m["want"] = "pinned (demoted)"
            m["why"] = f"pinning it would leave {usable - pinned - need:.1f} GiB, under the largest on-demand model ({largest_od():.1f})"
            warnings.append(f"{m['rs'][0].alias} wanted pinned but does not fit; demoted to on-demand")
    lod = max([m["size"] or 0 for m in models if m["got"] == "on-demand"] or [0.0])
    if usable is not None and pinned + lod > usable:
        warnings.append(f"the largest on-demand model ({lod:.1f} GiB) does not fit beside what is held ({pinned:.1f} GiB)")
    for m in models:
        for i, r in enumerate(m["rs"]):
            want = m["want"].replace(" (demoted)", "") if i else m["want"]
            rows.append(Placement(r.alias, r.model, r.endpoint, m["eng"], m["size"] if i == 0 else None, m["prio"],
                                  "pinned" if want.startswith("pinned") else want,
                                  m["got"] if m["want"] != "unprofiled" or m["got"] == "resident" else "unprofiled",
                                  m["why"] if i == 0 else "same model as above"))
    rows.sort(key=lambda p: (p.priority, p.alias))
    return Plan(node.id, usable, round(pinned, 1), lod, rows, warnings)


ENGINE_CMD = {
    "llama-server": "llama-server --host 127.0.0.1 --port ${PORT} -hf {model}",
    "mlx-lm": "mlx_lm.server --host 127.0.0.1 --port ${PORT} --model {model}",
}


def render_llama_swap(plan: Plan, ttl_s: int = 900, cmd: dict | None = None) -> dict:
    """llama-swap config (routing.router.use: group) for the plan's llama-server / mlx-lm models.
    Pinned models share a persistent group that nothing unloads; on-demand models swap one at a time
    and unload after ttl. Ollama is not behind llama-swap: it gets keep_alive instead (render_ollama)."""
    cmd = cmd or ENGINE_CMD
    models, pinned, od = {}, [], []
    for p in plan.placements:
        if p.engine not in cmd or p.got == "resident" or p.model in {m.get("useModelName") for m in models.values()}:
            continue
        mid = _slug(p.alias)
        models[mid] = {"cmd": cmd[p.engine].replace("{model}", p.model), "useModelName": p.model,
                       "ttl": 0 if p.got == "pinned" else ttl_s}
        if mid != p.alias:
            models[mid]["aliases"] = [p.alias]
        (pinned if p.got == "pinned" else od).append(mid)
    groups = {}
    if pinned:
        groups["pinned"] = {"persistent": True, "swap": False, "exclusive": False, "members": pinned}
    if od:
        groups["on-demand"] = {"swap": True, "exclusive": False, "members": od}
    cfg = {"healthCheckTimeout": 300, "models": models}
    if groups:
        cfg["routing"] = {"router": {"use": "group", "settings": {"groups": groups}}}
    if pinned:
        cfg["hooks"] = {"on_startup": {"preload": list(pinned)}}   # a copy: a shared list dumps as a YAML anchor
    return cfg


def render_ollama(plan: Plan, idle: str = "10m") -> dict:
    """Per-route keep_alive (passed through the gateway) and the daemon's loaded-model ceiling."""
    rows = [p for p in plan.placements if p.engine == "ollama"]
    keep = {p.alias: (-1 if p.got == "pinned" else idle) for p in rows}
    pinned_models = {p.model for p in rows if p.got == "pinned"}
    return {"routeParams": {a: {"keep_alive": v} for a, v in keep.items()},
            "env": {"OLLAMA_MAX_LOADED_MODELS": str(max(1, len(pinned_models) + 1)), "OLLAMA_KEEP_ALIVE": idle}}


# ---------------------------------------------------------------- pinned build vs what a node serves (TM-0934)
# Git holds the intended build; the node holds the actual one. For every catalogued Ollama or Hugging Face
# model with a pinned revision, each route that serves it is compared with what its node reports. The rule
# this section holds: a comparison it cannot make reads UNKNOWN with the reason, never current.

from .probe import norm_build as _norm_build, ollama_name  # noqa: E402  (the probe owns the node-side shapes)

DRIFT_KINDS = ("ollama", "huggingface")


@dataclass
class DriftRow:
    entry: Entry
    alias: str
    node: str
    endpoint: str
    pinned: str
    actual: str = ""
    state: str = "unknown"        # current | drift | unknown
    reason: str = ""
    how: str = ""


def same_build(pinned: str, actual: str) -> bool:
    """A pin may be written short (7+ hex); the node reports the whole digest or commit."""
    p, a = _norm_build(pinned), _norm_build(actual)
    return bool(p and a) and (a.startswith(p) or p.startswith(a))


def drift_targets(lc: Lifecycle, inv: Inventory) -> list[tuple[Entry, Route]]:
    """The (entry, route) pairs a build check covers: pinned Ollama and Hugging Face models that a route serves."""
    out = []
    for e in lc.catalog:
        if e.source.kind not in DRIFT_KINDS or not e.source.revision or e.stage == "retired":
            continue
        out += [(e, r) for r in inv.routes if r.model == e.model]
    return out


def build_drift(lc: Lifecycle, inv: Inventory, readings: dict, unread: str = "not checked yet") -> list[DriftRow]:
    """readings: (node id, endpoint id) -> a probe.BuildReading, or a string saying why it could not be read.
    A pair with no reading reads Unknown with `unread` as the reason."""
    rows = []
    for e, r in drift_targets(lc, inv):
        row = DriftRow(e, r.alias, r.node, r.endpoint, e.source.revision)
        got = readings.get((r.node, r.endpoint))
        n = inv.node(r.node)
        ep = n.endpoint(r.endpoint) if n else None
        if ep is None:
            row.reason = "the route names an endpoint the inventory does not have"
        elif got is None:
            row.reason = unread
        elif isinstance(got, str):
            row.reason = got
        elif got.reason:
            row.reason = got.reason
        elif e.source.kind == "ollama" and ep.engine != "ollama":
            row.reason = f"an Ollama digest is pinned but {r.endpoint} runs {ep.engine}"
        elif e.source.kind == "huggingface" and ep.engine == "ollama":
            row.reason = "a Hugging Face commit is pinned but the node runs it through Ollama, which reports its own digest"
        else:
            key = ollama_name(r.model) if ep.engine == "ollama" else r.model
            row.how = got.how
            if key not in got.builds:
                row.reason = f"{r.node} did not list {r.model}"
            elif not got.builds[key]:
                row.reason = f"{r.node} lists {r.model} but not which build"
            else:
                row.actual = got.builds[key]
                row.state = "current" if same_build(e.source.revision, row.actual) else "drift"
        rows.append(row)
    return rows


def drift_findings(rows: list[DriftRow]) -> list[str]:
    return [f"{x.alias} on {x.node} serves {x.entry.model} build {x.actual[:12]}, but the catalog pins "
            f"{_norm_build(x.pinned)[:12] or x.pinned}" for x in rows if x.state == "drift"]

# SPDX-License-Identifier: Apache-2.0
"""Platform Management: the Service Desk's cases and the specialists, read-only.

What the operations agents worked on and what is still pending, read from the Service Desk on the specialist host
(DESIGN-2026-10-24-platform-agent-network.md section 8). The host is features.platform.specialistsUrl; this page
calls it as client/tockmox-ui with the bearer token in features.platform.specialistsTokenFile, and the desk admits
that caller to three reads only: list, get and timeline.

The rules this page keeps, from the UI design and the agent-network design:
  - It writes nothing and renders no model output. Every timeline entry carries `src`, decided by the desk from the
    host-authenticated caller and the host's model provenance: desk (the desk's own words: an alert, a hand-off) and
    agent (a specialist with no model answer in its call chain) render; model, client and anything unlabelled show
    that the step happened, who did it, when and its links, and leave the words to the conversation.
  - Absence is not green. A desk that does not answer reads Unknown, never an empty list of cases.
  - A link renders only as an https URL or as a record id this desk knows.
  - A role's cases are the records it is accountable for (the desk's roles table) plus the records one of its
    specialists worked (the catalog's specialists field, generated from the same roles file).
"""
from __future__ import annotations

import logging
import os
import re

import httpx
from fastapi import Request

from .sources import OK, UNKNOWN, WARN, Source, _parse_ts

log = logging.getLogger("tockmox_ui.platform")

TYPE_WORDS = {"incident": "Incident", "problem": "Problem", "change": "Change", "known_error": "Known error"}
STATE_WORDS = {
    "new": "New", "triaged": "Triaged", "mitigating": "Mitigating", "restored": "Restored", "closed": "Closed",
    "investigating": "Investigating", "root_cause_known": "Root cause known", "fix_proposed": "Fix proposed",
    "resolved": "Resolved", "draft": "Draft", "submitted": "Submitted", "approved": "Approved", "rejected": "Rejected",
    "applying": "Applying", "applied": "Applied", "failed": "Failed", "rolled_back": "Rolled back",
    "verified": "Verified", "open": "Open", "documented": "Documented", "retired": "Retired",
}
KIND_WORDS = {
    "opened": "Opened", "state": "Moved", "link": "Linked", "note": "Note", "evidence": "Evidence", "action": "Action",
    "verification": "Verified", "alert": "Alert", "alert_resolved": "Alert resolved", "link_out": "Link",
    "dispatch": "Handed on", "dispatch_failed": "Hand-off failed", "escalation": "Paged you", "truncated": "Older steps",
    "needs_you": "Asked you",
}
ASK_WORDS = {
    "approve_restore": "Approve a restore no standard change covers",
    "no_standard_action": "Decide a restore: the runbook has no standard action for this cause",
    "no_target": "Name the workload: the alert does not say which one",
    "cannot_explain": "Look at it: the Cluster Operator could not explain the workload",
    "no_root_cause": "Help find the cause: the revision history does not show one",
    "manifest_path": "Fix where the manifest lives: the path is not a plain relative path",
    "literal_secret": "Move a credential into a Secret before a fix can be proposed",
    "manifest_too_large": "Look at the change: the manifest is larger than the analyst may send",
    "change_refused": "Look at the change: the GitOps Engineer refused it",
    "pr_not_opened": "Look at the change: the GitOps Engineer did not open a PR",
    "desk_refused": "Look at the records: the desk refused a move the analyst needed",
    "decision": "A decision",
}
WAIT_WORDS = {
    "jeff": "You", "agent": "An agent", "role": "Its role", "attention": "A person: a hand-off failed",
    "record": "A linked record",
}
REASON_WORDS = {"decision": "asked you", "paged": "paged you", "approval": "waits for your approval of the PR",
                "queued": "handed on", "in_progress": "working it", "hand_off_failed": "hand-off failed",
                "linked": "waits on a linked record"}
SHOWN_SRC = ("desk", "agent")
LINK_WORDS = {"caused_by": "Caused by", "causes": "Causes", "fixed_by": "Fixed by", "fixes": "Fixes",
              "documents": "Documents", "documented_by": "Documented by", "related": "Related to",
              "duplicate_of": "Duplicate of", "duplicated_by": "Duplicated by"}
# Kinds only the desk writes; before 1.2.0 entries carried no src, and these were still the desk's words when the desk
# itself (its schedule, or an event it took in) wrote them. `alert` is not here: any caller may write that kind.
DESK_KINDS = ("dispatch", "dispatch_failed", "escalation", "alert_resolved", "truncated", "link")
REC_ID = re.compile(r"[A-Z]{2,4}-\d{4,}")
WORD = re.compile(r"[a-z][a-z0-9_]{0,47}")
SPEC_ID = re.compile(r"[a-z][a-z0-9-]{1,47}")
# Facts and names are shown only in their own shape: a free sentence in any of them reads as nothing
NAMEISH = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@-]{0,199}")
FACT_SHAPES = {"alertname": re.compile(r"[A-Za-z_:][A-Za-z0-9_:]{0,127}"), "cause": WORD, "kind": WORD,
               "repo": NAMEISH, "path": NAMEISH, "venue": WORD, "approved_by": NAMEISH, "approval_ref": NAMEISH,
               "submission": re.compile(r"s-[0-9a-f]{6,24}"), "known_error": REC_ID, "incident": REC_ID,
               "escalated_at": re.compile(r"\d{4}-\d{2}-\d{2}T[0-9:.]+Z")}
TITLE_SRC = ("desk", "agent")
FACT_KEYS = ("alertname", "cause", "standing", "escalated_at", "alert_firing", "pr_url", "repo", "path", "venue",
             "approved_by", "approval_ref", "submission", "known_error", "incident", "kind",
             "label_namespace", "label_severity", "label_deployment", "label_pod", "label_service", "label_job")
SUMMARY_KEYS = ("id", "type", "title", "state", "service", "severity", "trace_id", "created", "updated",
                "state_since", "closed", "role", "stuck")


def _https(v) -> str:
    return v if isinstance(v, str) and v.startswith("https://") and len(v) <= 500 and not any(c in v for c in '"<> ') else ""


def _short(v, n=300) -> str:
    return " ".join(str(v).split())[:n] if v is not None else ""


def clean_summary(r: dict) -> dict | None:
    """One worklist row, allowlisted. A row without a well-formed id is dropped, not shown half-read."""
    if not isinstance(r, dict) or not REC_ID.fullmatch(str(r.get("id") or "")):
        return None
    out = {k: r.get(k) for k in SUMMARY_KEYS}
    out["title_src"] = r.get("title_src") if r.get("title_src") in ("desk", "agent", "model", "client") else "unlabelled"
    out["title"] = _short(out["title"], 300) if out["title_src"] in TITLE_SRC else ""
    out["service"] = _short(out["service"], 200) if NAMEISH.fullmatch(str(out["service"] or "")) else ""
    out["type"] = out["type"] if out["type"] in TYPE_WORDS else "record"
    out["state"] = str(out["state"] or "") if WORD.fullmatch(str(out["state"] or "")) else "unknown"
    out["role"] = str(out["role"]) if SPEC_ID.fullmatch(str(out["role"] or "")) else ""
    out["closed"], out["stuck"] = bool(out["closed"]), bool(out["stuck"])
    w = r.get("waiting") if isinstance(r.get("waiting"), dict) else None
    out["waiting"] = None
    if w and w.get("on") in WAIT_WORDS:
        out["waiting"] = {"on": w["on"], "reason": w.get("reason") if w.get("reason") in REASON_WORDS else "",
                          "ask": w.get("ask") if WORD.fullmatch(str(w.get("ask") or "")) else "",
                          "specialist": w.get("specialist") if SPEC_ID.fullmatch(str(w.get("specialist") or "")) else "",
                          "op": w.get("op") if WORD.fullmatch(str(w.get("op") or "")) else "",
                          "role": w.get("role") if SPEC_ID.fullmatch(str(w.get("role") or "")) else "",
                          "record": w.get("record") if REC_ID.fullmatch(str(w.get("record") or "")) else "",
                          "rel": w.get("rel") if w.get("rel") in ("caused_by", "fixed_by") else "",
                          "since": w.get("since")}
    elif not out["closed"]:
        out["waiting"] = {"on": "unknown", "reason": "", "ask": "", "specialist": "", "op": "", "role": "", "record": "",
                          "rel": "", "since": None}
    out["worked_by"] = [s for s in (r.get("worked_by") or []) if isinstance(s, str) and SPEC_ID.fullmatch(s)][:20]
    out["links"] = [{"rel": l["rel"], "id": l["id"]} for l in (r.get("links") or [])
                    if isinstance(l, dict) and WORD.fullmatch(str(l.get("rel") or "")) and REC_ID.fullmatch(str(l.get("id") or ""))][:20]
    facts = r.get("facts") if isinstance(r.get("facts"), dict) else {}
    out["facts"] = {}
    for k in FACT_KEYS:
        v = facts.get(k)
        if k.endswith("_url"):
            v = _https(v)
        elif isinstance(v, str) and not (FACT_SHAPES.get(k) or NAMEISH).fullmatch(v):
            continue
        if isinstance(v, bool) or (isinstance(v, (int, float)) and not isinstance(v, bool)) or (isinstance(v, str) and v):
            out["facts"][k] = v if not isinstance(v, str) else _short(v, 300)
    for k in ("created", "updated", "state_since"):
        out[k + "_ts"] = _parse_ts(out.get(k)) if out.get(k) else None
    if out["waiting"]:
        out["waiting"]["since_ts"] = _parse_ts(out["waiting"]["since"]) if out["waiting"].get("since") else None
    return out


def clean_entry(e: dict, known_ids: set) -> dict | None:
    """One timeline step: who, what kind, when, links; its words only when the desk or a rule wrote them."""
    if not isinstance(e, dict):
        return None
    kind = str(e.get("kind") or "")
    src = e.get("src")
    actor = str(e.get("actor") or "")
    shown = src in SHOWN_SRC or (src is None and kind in DESK_KINDS and (actor == "schedule" or actor.startswith("event/")))
    refs = []
    for r in e.get("refs") or []:
        if isinstance(r, str) and REC_ID.fullmatch(r):
            refs.append({"id": r, "url": f"/platform/cases/{r}" if r in known_ids else ""})
        elif _https(r) and shown:      # an outside link only on a step whose words the page shows
            refs.append({"id": "", "url": _https(r)})
    frm, to = e.get("from"), e.get("to")
    if kind == "state" and not (frm and to):
        m = re.match(r"^([a-z_]+) -> ([a-z_]+)", str(e.get("text") or ""))    # before 1.2.0: the desk's own prefix
        frm, to = (m.group(1), m.group(2)) if m else (None, None)
    text = _short(e.get("text"), 600) if shown else ""
    if kind == "state" and text:
        text = re.sub(r"^[a-z_]+ -> [a-z_]+:\s*", "", text)        # the move is shown as from -> to already
    if kind == "link" and text:
        text = LINK_WORDS.get(text.split(" ", 1)[0], "Linked to")
    return {"ts": e.get("ts"), "t": _parse_ts(e.get("ts")) if e.get("ts") else None, "kind": kind,
            "kind_word": KIND_WORDS.get(kind, kind or "Step"),
            "actor": actor, "specialist": actor[11:] if actor.startswith("specialist/") else "",
            "src": src or "unlabelled", "text": text,
            "hidden": not shown and bool(e.get("text")),
            "from": frm if WORD.fullmatch(str(frm or "")) else "", "to": to if WORD.fullmatch(str(to or "")) else "",
            "ask": e.get("ask") if WORD.fullmatch(str(e.get("ask") or "")) else "", "refs": refs[:10]}


class _Host:
    def __init__(self, url, timeout, token_file="", transport=None):
        self.url, self.timeout, self.token_file, self.transport = url.rstrip("/"), timeout, token_file, transport

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.token_file and os.path.exists(self.token_file):
            with open(self.token_file, encoding="utf-8") as fh:
                h["Authorization"] = "Bearer " + fh.read().strip()
        return h

    def call(self, op, args):
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport, headers=self._headers()) as c:
            r = c.post(f"/s/service-desk/v1/{op}", json=args)
            r.raise_for_status()
            doc = r.json()
        if not isinstance(doc, dict) or "outcome" not in doc:
            raise ValueError("the desk answered without an outcome")
        return doc

    def index(self):
        with httpx.Client(base_url=self.url, timeout=self.timeout, transport=self.transport) as c:
            r = c.get("/v1/index")
            r.raise_for_status()
            doc = r.json()
        if not isinstance(doc, dict) or not isinstance(doc.get("specialists"), list):
            raise ValueError("the index answered without a list of specialists")
        return doc


class DeskSource(Source):
    """The worklist: every open record and every record closed in the last WINDOW_H hours, newest activity first."""
    name = "Service Desk"
    LIMIT = 500
    WINDOW_H = 24 * 30

    def __init__(self, url, timeout, token_file="", transport=None, ttl=15.0):
        super().__init__(ttl)
        self.host = _Host(url or "", timeout, token_file, transport)
        self.url = url or ""

    def configured(self):
        return bool(self.url)

    def fetch(self):
        # Open records in their own read, so a long closed history can never push an open ask out of the answer
        doc = self.host.call("list", {"limit": self.LIMIT, "open_only": True})
        if doc.get("outcome") != "ok" or not isinstance(doc.get("records"), list):
            raise ValueError(f"the desk's list answered {doc.get('outcome')!r}")
        done = self.host.call("list", {"limit": self.LIMIT, "closed_within_hours": self.WINDOW_H})
        if done.get("outcome") != "ok" or not isinstance(done.get("records"), list):
            raise ValueError(f"the desk's list answered {done.get('outcome')!r}")
        seen = {r.get("id") for r in doc["records"] if isinstance(r, dict)}
        merged = list(doc["records"]) + [r for r in done["records"] if isinstance(r, dict) and r.get("closed") and r.get("id") not in seen]
        rows = [x for x in (clean_summary(r) for r in merged) if x]
        follow(rows)
        att = [a for a in doc.get("needs_attention") or [] if isinstance(a, dict) and REC_ID.fullmatch(str(a.get("record_id") or ""))]
        return {"records": rows, "count": int(doc.get("count") or 0), "open_returned": len(doc["records"]), "attention": len(att)}

    def evaluate(self, data):
        if data["count"] > data["open_returned"]:
            return WARN, f"answered {data['open_returned']} of its {data['count']} open records only; an older one waiting on you may not show"
        if any(r.get("waiting") and r["waiting"]["on"] == "unknown" for r in data["records"]):
            return WARN, "some open records do not say what they wait on (the desk is older than 1.2.0)"
        return OK, f"{data['count']} records"

    def case(self, rid):
        """One record with its timeline, cleaned; None when the desk has no such record."""
        doc = self.host.call("get", {"id": rid})
        if doc.get("outcome") == "not_found":
            return None
        rec = doc.get("record")
        if doc.get("outcome") != "found" or not isinstance(rec, dict):
            raise ValueError(f"the desk's get answered {doc.get('outcome')!r}")
        return rec


class IndexSource(Source):
    """The specialist host's index (no auth): which specialists it serves, at which version, and the roles file's hash."""
    name = "Specialist host"

    def __init__(self, url, timeout, transport=None, ttl=60.0):
        super().__init__(ttl)
        self.host = _Host(url or "", timeout, "", transport)
        self.url = url or ""

    def configured(self):
        return bool(self.url)

    def fetch(self):
        doc = self.host.index()
        served = {}
        for s in doc["specialists"]:
            if isinstance(s, dict) and SPEC_ID.fullmatch(str(s.get("id") or "")):
                served[s["id"]] = {"version": _short(s.get("version"), 20), "status": _short(s.get("status"), 20),
                                   "title": _short(s.get("title"), 80), "owner_role": _short(s.get("owner_role"), 60)}
        roles = doc.get("roles") if isinstance(doc.get("roles"), dict) else {}
        sha = roles.get("sha256") if re.fullmatch(r"[0-9a-f]{64}", str(roles.get("sha256") or "")) else ""
        return {"served": served, "roles_sha256": sha}

    def evaluate(self, data):
        return OK, f"{len(data['served'])} specialists served"


def follow(rows):
    """Where a record that waits on a linked record ends up: the first record down the chain that waits on something
    else (Jeff, an agent, a role, a failed hand-off). Shown as text beside the record's own state, never counted twice."""
    by = {r["id"]: r for r in rows}
    for r in rows:
        r["via"], r["end"] = [], None
        cur, seen = r, {r["id"]}
        while cur.get("waiting") and cur["waiting"]["on"] == "record" and cur["waiting"]["record"] in by \
                and cur["waiting"]["record"] not in seen and len(seen) < 6:
            cur = by[cur["waiting"]["record"]]
            seen.add(cur["id"])
            r["via"].append(cur["id"])
        if r["via"]:
            r["end"] = {"id": cur["id"], "waiting": cur.get("waiting")}


# ---------------------------------------------------------------- views

def role_cases(agent, rows):
    """A role's cases: the ones it is accountable for, and the ones one of its specialists worked."""
    mine = {s["id"] for s in agent.specialists}
    out = []
    for r in rows:
        if agent.agent_role and r["role"] == agent.agent_role:
            out.append(dict(r, why="accountable"))
        elif mine & set(r["worked_by"]):
            out.append(dict(r, why="worked"))
    return out


def pending_order(r):
    w = r.get("waiting") or {}
    rank = {"attention": 0, "jeff": 1, "unknown": 2, "agent": 3, "role": 4, "record": 5}.get(w.get("on"), 6)
    return (rank, 0 if r.get("stuck") else 1, r.get("state_since_ts") or r.get("updated_ts") or 0)


def split(rows):
    pending = sorted([r for r in rows if not r["closed"]], key=pending_order)
    done = sorted([r for r in rows if r["closed"]], key=lambda r: r.get("updated_ts") or 0, reverse=True)
    return pending, done


def specialist_roles(cat):
    """specialist id -> [(catalog role id, role name)] in catalog order."""
    out = {}
    for a in cat.all():
        for s in a.specialists:
            out.setdefault(s["id"], []).append((a.id, a.name))
    return out


def roles_by_agent_role(cat):
    return {a.agent_role: a for a in cat.all() if a.agent_role}


def summarize(rows):
    pending, done = split(rows)
    return {"unknown": sum(1 for r in pending if not r["waiting"] or r["waiting"]["on"] == "unknown"),
            "open": len(pending), "jeff": sum(1 for r in pending if r["waiting"] and r["waiting"]["on"] in ("jeff", "attention")),
            "stuck": sum(1 for r in pending if r["stuck"]), "closed": len(done),
            "agent": sum(1 for r in pending if r["waiting"] and r["waiting"]["on"] in ("agent", "role", "record"))}


def register(app, cat, srcs, guard, render, common):
    """The Cases pages and the Specialists page; the agent and overview pages read the same sources."""

    def desk_rows():
        r = srcs["desk"].read()
        return r, ((r.data or {}).get("records") or []) if r.fetched_at is not None else []

    @app.get("/platform/cases")
    def cases(request: Request, role: str = ""):
        u, deny = guard(request)
        if deny:
            return deny
        r, rows = desk_rows()
        sel = cat.get(role) if role else None
        if role and sel is None:
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="There is no such role in this platform's organization.")
        shown = role_cases(sel, rows) if sel else rows
        pending, done = split(shown)
        return render(request, "platform_cases.html", u, desk=r, desk_on=srcs["desk"].configured(), pending=pending,
                      done=done, sel=sel, counts=summarize(shown),
                      roles=[a for a in cat.all() if role_cases(a, rows)], **common(u))

    @app.get("/platform/cases/{rid}")
    def case(request: Request, rid: str):
        u, deny = guard(request)
        if deny:
            return deny
        rid = rid.strip().upper()
        if not REC_ID.fullmatch(rid):
            return render(request, "error.html", u, status_code=404, title="Not found", message="That is not a case id.")
        if not srcs["desk"].configured():
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message="No Service Desk is connected, so this page has no cases to show.")
        r, rows = desk_rows()
        known = {x["id"] for x in rows}
        try:
            rec = srcs["desk"].case(rid)
        except Exception as e:  # noqa: BLE001 - the page says Unknown and why, never a crash
            log.warning("platform: desk get %s failed: %s", rid, type(e).__name__)
            return render(request, "error.html", u, status_code=503, title="The Service Desk did not answer",
                          message=f"This page could not read {rid} from the Service Desk ({type(e).__name__}). "
                                  "That is not the same as the case being closed or gone.")
        if rec is None:
            return render(request, "error.html", u, status_code=404, title="Not found",
                          message=f"The Service Desk has no record {rid}.")
        row = next((x for x in rows if x["id"] == rid), None)
        if row is None:        # outside the list's window: say what can be said, and that the rest is unknown
            row = clean_summary({k: rec.get(k) for k in ("id", "type", "title", "state", "service", "severity", "trace_id",
                                                         "created", "updated")})
            if row:
                row["waiting"] = {"on": "unknown", "reason": "", "ask": "", "specialist": "", "op": "", "role": "",
                                  "record": "", "rel": "", "since": None, "since_ts": None}
        known |= {rid}
        steps = [x for x in (clean_entry(e, known) for e in rec.get("timeline") or []) if x]
        family = sorted([x for x in rows if x["trace_id"] == row.get("trace_id") and x["id"] != rid],
                        key=lambda x: x.get("created_ts") or 0)
        return render(request, "platform_case.html", u, row=row, steps=steps, family=family, desk=r,
                      kind_words=KIND_WORDS, **common(u))

    @app.get("/platform/specialists")
    def specialists(request: Request):
        u, deny = guard(request)
        if deny:
            return deny
        idx = srcs["index"].read()
        served = (idx.data or {}).get("served") or {} if idx.fetched_at is not None else {}
        rows = []
        for sid, owners in sorted(specialist_roles(cat).items()):
            state = next((s["state"] for a in cat.all() for s in a.specialists if s["id"] == sid and s["state"] == "built"),
                         None) or next(s["state"] for a in cat.all() for s in a.specialists if s["id"] == sid)
            rows.append({"id": sid, "owners": owners, "state": state, "served": served.get(sid)})
        return render(request, "platform_specialists.html", u, rows=rows, index=idx, index_on=srcs["index"].configured(),
                      drift=drift(cat, idx), catalog_source=cat.specialists_source, **common(u))


def drift(cat, idx):
    """The catalog's specialists field was generated from a roles file other than the one the host serves."""
    if idx.fetched_at is None or not cat.specialists_source:
        return ""
    theirs = (idx.data or {}).get("roles_sha256") or ""
    ours = str(cat.specialists_source.get("sha256") or "")
    if theirs and ours and theirs != ours:
        return (f"The specialists listed on these pages were generated from a roles file ({ours[:12]}) other than the one "
                f"the specialist host serves ({theirs[:12]}). Re-run tools/gen-platform-specialists.py and ship the catalog.")
    return ""


__all__ = ["DeskSource", "IndexSource", "register", "role_cases", "split", "summarize", "drift", "clean_entry",
           "clean_summary", "ASK_WORDS", "WAIT_WORDS", "REASON_WORDS", "STATE_WORDS", "TYPE_WORDS", "UNKNOWN"]

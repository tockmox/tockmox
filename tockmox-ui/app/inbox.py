# SPDX-License-Identifier: Apache-2.0
"""The Models inbox (TM-1258, TM-1265): what the watcher found, as cards a person decides about, and when a hosted model
retires.

Pure: no I/O, no clock reads except where a caller passes `today`. The watcher (app/watcher.py) and the PR opener read the
same inbox lists through skipped_ids(), so a snoozed or dismissed candidate is not offered by any of the three.

    modelLifecycle:
      inbox:
        snoozed:   [{id: "quant:example-org/Example-30B-4bit", until: "2026-11-29"}]    # hidden until that date
        dismissed: [{id: "successor:example-org/Example-3-27B", date: "2026-10-30"}]    # hidden until a NEW candidate id

A candidate id names what was found (kind, repo and, for a new revision, the commit), so dismissing "revision:repo@abc" does not
hide the next commit. Neither list is ever written by the UI: Snooze and Dismiss render a values change for a person to commit.
"""
from __future__ import annotations

import copy
import datetime
import re
from dataclasses import dataclass, field

from . import models as ml

SNOOZE_DAYS = 30
MAX_ENTRIES = 500
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# the reason tag on a card: (word, what it means)
REASONS = {
    "revision": ("New revision", "a new build of a model you run"),
    "digest": ("New revision", "a new build of a model you run"),
    "quant": ("Other quant", "another quantisation of a model you run"),
    "successor": ("Successor", "a newer model in a family you run"),
    "frontier": ("Hosted, new", "a hosted model the gateway does not route yet"),
    "deprecation": ("Hosted, retiring", "a hosted model its provider is retiring"),
}


@dataclass
class Inbox:
    snoozed: dict = field(default_factory=dict)      # candidate id -> until (YYYY-MM-DD)
    dismissed: dict = field(default_factory=dict)    # candidate id -> date dismissed (YYYY-MM-DD, "" when not recorded)


def _entries(raw, key, date_key, required):
    if raw in (None, []):
        return {}
    if not isinstance(raw, list) or len(raw) > MAX_ENTRIES:
        raise ml.LifecycleError(f"modelLifecycle.inbox.{key} must be a list of at most {MAX_ENTRIES} {{id, {date_key}}}")
    out = {}
    for i, x in enumerate(raw):
        if isinstance(x, str) and not required:
            x = {"id": x}
        cid = x.get("id") if isinstance(x, dict) else None
        d = str((x or {}).get(date_key, "") or "") if isinstance(x, dict) else ""
        if not isinstance(cid, str) or not 0 < len(cid) <= 200 or any(c.isspace() for c in cid):
            raise ml.LifecycleError(f"modelLifecycle.inbox.{key}[{i}] needs an id (a candidate id from the watcher's report)")
        if (required or d) and not _DATE.match(d):
            raise ml.LifecycleError(f"modelLifecycle.inbox.{key}[{i}].{date_key} must be a date (YYYY-MM-DD)")
        out[cid] = d
    return out


def parse(raw) -> Inbox:
    if raw in (None, {}):
        return Inbox()
    if not isinstance(raw, dict):
        raise ml.LifecycleError("modelLifecycle.inbox must be a mapping with snoozed and dismissed lists")
    return Inbox(_entries(raw.get("snoozed"), "snoozed", "until", True), _entries(raw.get("dismissed"), "dismissed", "date", False))


def _today(today) -> datetime.date:
    return today.date() if isinstance(today, datetime.datetime) else today


def skipped_ids(inbox: Inbox, today) -> set:
    """Candidate ids nobody should be offered today: every dismissed one, and a snoozed one until its date."""
    t = _today(today).isoformat()
    return set(inbox.dismissed) | {cid for cid, until in inbox.snoozed.items() if until > t}


def split(cands, inbox: Inbox, today):
    """(shown, snoozed, dismissed): the candidates to offer, and the two lists that are hidden, each with why."""
    t = _today(today).isoformat()
    shown, snoozed, dismissed = [], [], []
    for c in cands:
        if c.id in inbox.dismissed:
            dismissed.append((c, inbox.dismissed[c.id]))
        elif inbox.snoozed.get(c.id, "") > t:
            snoozed.append((c, inbox.snoozed[c.id]))
        else:
            shown.append(c)
    return shown, snoozed, dismissed


def _raw_lists(raw_inbox):
    base = copy.deepcopy(raw_inbox) if isinstance(raw_inbox, dict) else {}
    return base, [x for x in (base.get("snoozed") or []) if isinstance(x, dict)], [x for x in (base.get("dismissed") or []) if x]


def with_snooze(raw_inbox, cid: str, today, days: int = SNOOZE_DAYS) -> dict:
    """The inbox mapping after snoozing `cid` for `days`: expired snoozes are dropped, an older entry for the same id is replaced."""
    base, snoozed, dismissed = _raw_lists(raw_inbox)
    t = _today(today)
    keep = [x for x in snoozed if str(x.get("until", "")) > t.isoformat() and x.get("id") != cid]
    keep.append({"id": cid, "until": (t + datetime.timedelta(days=days)).isoformat()})
    dismissed = [x for x in dismissed if (x.get("id") if isinstance(x, dict) else x) != cid]
    base["snoozed"], base["dismissed"] = keep, dismissed
    if not dismissed:
        del base["dismissed"]
    return base


def with_dismiss(raw_inbox, cid: str, today) -> dict:
    base, snoozed, dismissed = _raw_lists(raw_inbox)
    t = _today(today)
    snoozed = [x for x in snoozed if str(x.get("until", "")) > t.isoformat() and x.get("id") != cid]
    dismissed = [x for x in dismissed if (x.get("id") if isinstance(x, dict) else x) != cid] + [{"id": cid, "date": t.isoformat()}]
    base["snoozed"], base["dismissed"] = snoozed, dismissed
    if not snoozed:
        del base["snoozed"]
    return base


# ---------------------------------------------------------------- when a hosted model retires (TM-1265)

def parse_date(raw) -> datetime.date | None:
    """A provider's shutdown date: YYYY-MM-DD (with or without a time), or epoch seconds."""
    s = str(raw or "").strip()
    if re.match(r"^\d{4}-\d{2}-\d{2}", s):
        try:
            return datetime.date.fromisoformat(s[:10])
        except ValueError:
            return None
    if re.match(r"^\d{9,11}$", s):
        try:
            return datetime.datetime.fromtimestamp(int(s), datetime.timezone.utc).date()
        except (OverflowError, OSError, ValueError):
            return None
    return None


def retirement(when, today) -> dict:
    """{state: upcoming | retired | unknown, days, date, text} for a deprecation candidate's `when`. Past is "retired", never a
    negative count; a date nobody can read is Unknown, not "retires in 0 days"."""
    d = parse_date(when)
    t = _today(today)
    if d is None:
        return {"state": "unknown", "days": None, "date": "", "text": "retirement date not understood" + (f" ({str(when)[:40]})" if when else "")}
    n = (d - t).days
    if n < 0:
        return {"state": "retired", "days": n, "date": d.isoformat(), "text": f"retired on {d.isoformat()}"}
    if n == 0:
        return {"state": "upcoming", "days": 0, "date": d.isoformat(), "text": "retires today"}
    return {"state": "upcoming", "days": n, "date": d.isoformat(), "text": f"retires in {n} day{'s' if n != 1 else ''} ({d.isoformat()})"}


def retire_map(report, today) -> dict:
    """{hosted model id: retirement() + replacement} from the report's deprecation candidates. A model listed twice keeps the
    earliest date."""
    out = {}
    for c in (report.candidates if report else []):
        if c.kind != "deprecation":
            continue
        r = {**retirement(c.when, today), "replacement": c.replacement, "candidate": c.id}
        old = out.get(c.model)
        if old is None or (r["date"] and (not old["date"] or r["date"] < old["date"])):
            out[c.model] = r
    return out


def retire_for(rmap: dict, *models) -> dict | None:
    return next((rmap[m] for m in models if m and m in rmap), None)


def retire_state(r: dict) -> str:
    """The badge state for a countdown: a retired model is a Problem; one that is going is a Warning; an unreadable date is Unknown."""
    return {"retired": "critical", "upcoming": "warning"}.get(r["state"], "unknown")
